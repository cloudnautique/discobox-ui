import Foundation
import Observation

@MainActor @Observable public final class ConnectionSession: Identifiable {
    public let id: String
    public private(set) var profile: ConnectionProfile
    public let connectionState: ConnectionStore
    public let inventory: BoxInventoryStore
    public let selection: BoxSelectionStore
    public let approvalStore: ApprovalStore
    public let catalog: HarnessCatalogStore
    public let pending: PendingBoxOperations
    public let pools: PoolCommands
    public let commands: BoxCommands
    public let credentials: CredentialService
    public let harnessService: HarnessService
    public let audit: AuditService
    public let poolSettings: PoolSettingsService
    public let tools: ToolService
    public let links: LinkService
    public private(set) var usage = HarnessUsage()
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var polling: [Task<Void, Never>] = []
    @ObservationIgnored private var attempt = UUID()
    func beginConnection() -> UUID { stopPolling(); return attempt }
    func ownsAttempt(_ value: UUID) -> Bool { attempt == value }
    public init(profile: ConnectionProfile = .thisComputer, now: @escaping () -> Date = Date.init) {
        self.profile = profile
        id = ConnectionProfiles.normalizedEndpoint(profile.endpoint)
        self.now = now
        let connection = ConnectionStore(), inventory = BoxInventoryStore(), pending = PendingBoxOperations()
        connectionState = connection; self.inventory = inventory; self.pending = pending
        selection = BoxSelectionStore(connection: connection, inventory: inventory, pending: pending, now: now)
        approvalStore = ApprovalStore(connection: connection)
        catalog = HarnessCatalogStore(connection: connection, now: now)
        pools = PoolCommands(connection: connection, inventory: inventory, selection: selection, pending: pending, now: now)
        commands = BoxCommands(connection: connection, inventory: inventory, selection: selection, pending: pending, pools: pools, now: now)
        credentials = CredentialService(connection: connection)
        harnessService = HarnessService(connection: connection)
        audit = AuditService(connection: connection)
        poolSettings = PoolSettingsService(connection: connection)
        tools = ToolService(connection: connection)
        links = LinkService(connection: connection)
        pools.refresh = { [weak self] in await self?.refresh() }
        commands.refresh = { [weak self] in await self?.refresh() }
    }
    /// Existing refreshes advance this only when an age check could change,
    /// so unchanged reports still age out without republishing every tick.
    public private(set) var activityClock = ActivityClock()
    var activityObservationTime: Date { activityClock.now }
    func advanceActivityClock() {
        let next = activityClock.advanced(to: now(), inventoryObservedAt: inventory.boxesObservedAt, reportDates: reportDates)
        if next != activityClock { activityClock = next }
    }
    /// Parsed once per box list, not on every approvals poll.
    @ObservationIgnored private var reportDatesCache: (boxes: [Sandbox], dates: [Date])?
    private var reportDates: [Date] {
        if let cache = reportDatesCache, cache.boxes == inventory.sandboxes { return cache.dates }
        let dates = ActivityClock.reportDates(inventory.sandboxes)
        reportDatesCache = (inventory.sandboxes, dates)
        return dates
    }
    public func update(_ profile: ConnectionProfile) { self.profile = profile }
    typealias Poll = PollingLoop
    @ObservationIgnored var pollSleep: @Sendable (Poll, Double) async throws -> Void = { _, delay in
        try await Task.sleep(for: .seconds(delay))
    }
    /// Set by Connections from window presence and the active computer. A change
    /// wakes sleeping loops so they recompute their deadline from the last poll.
    public let readMetrics = ReadMetrics()
    @ObservationIgnored private var scheduledReads: [Poll: Task<Void, Never>] = [:]
    func applyRefreshPolicy(_ value: RefreshPolicy) {
        readMetrics.apply(value)
        for (kind, task) in scheduledReads where !value.allows(kind) { task.cancel() }
        if value.manual { hydrateTask?.cancel(); hydrateTask = nil }
        schedule.wake()
    }
    @ObservationIgnored var cadence = PollingCadence() {
        didSet {
            if cadence != oldValue {
                if !cadence.showsComputer || cadence.presence == .hidden { sidebarInventoryDue = false }
                for (kind, task) in scheduledReads where cadence.interval(kind) == nil { task.cancel() }
                schedule.wake()
            }
        }
    }
    @ObservationIgnored private var sidebarInventoryDue = false
    func requestSidebarInventory(force: Bool) {
        guard sidebarRead == nil, scheduledReads[.inventory] == nil, connectionState.isConnected,
              connectionState.connectionError == nil, readMetrics.policy.allows(.inventory) else { return }
        if !force, let observed = inventory.boxesObservedAt, now().timeIntervalSince(observed) <= 5 { return }
        sidebarInventoryDue = true
        schedule.wake()
    }
    @ObservationIgnored private let schedule = PollingSchedule()
    func startPolling() {
        stopPolling()
        let sleep = pollSleep, schedule = schedule
        polling = Poll.allCases.map { kind in
            Task(priority: kind == .resources || kind == .usage ? .utility : nil) { [weak self] in
                // Inventory waits one interval first. Others poll at once, unless
                // paused (resources, usage while hidden): they are then due as
                // soon as the cadence resumes them.
                var last: Date? = kind == .inventory ? self?.now() : nil
                if kind != .inventory, self?.cadence.interval(kind) != nil { await self?.poll(kind); last = self?.now() }
                while !Task.isCancelled {
                    // Sleeping holds only the schedule, never this session.
                    do {
                        waiting: while true {
                            guard let wait = self?.pollWait(kind, since: last) else { return }
                            switch wait {
                            case .due: break waiting
                            case .after(let seconds): if try await !schedule.sleep(kind, seconds: seconds, using: sleep) { break waiting }
                            case .paused: _ = try await schedule.sleep(kind, seconds: nil, using: sleep)
                            }
                        }
                    } catch { return }
                    guard !Task.isCancelled else { return }
                    if kind == .inventory { self?.sidebarInventoryDue = false }
                    await self?.poll(kind)
                    last = self?.now() ?? last
                }
            }
        }
        observeRecovery(attempt)
    }
    @ObservationIgnored private let events = ProjectEventSubscription()
    @ObservationIgnored private var hydrateTask: Task<Void, Never>?
    private(set) var eventsCurrent = false

    private func setEventsCurrent(_ value: Bool) {
        if value != eventsCurrent { eventsCurrent = value; schedule.wake() }
    }
    private func stopEvents() {
        events.stop()
        hydrateTask?.cancel(); hydrateTask = nil
        inventory.resumeListing()
        setEventsCurrent(false)
    }
    private func ensureEvents() {
        guard let source = connectionState.client as? any ProjectEventSource,
              let project = connectionState.projectID else { return }
        let endpoint = connectionState.transportEndpoint
        let owner = connectionState.connectionID
        events.start(source: source, project: project, endpoint: endpoint, connection: owner) { [weak self] changes, current in
            guard let self, self.connectionState.connectionID == owner,
                  self.connectionState.transportEndpoint == endpoint else { throw CancellationError() }
            self.setEventsCurrent(current)
            guard let changes else { self.inventory.resumeListing(); return }
            if self.inventory.apply(changes) { self.hydrateNewBoxes(owner) }
            if !changes.isEmpty {
                self.selection.reconcileInventory()
                self.advanceActivityClock()
            }
        }
    }

    private func hydrateNewBoxes(_ owner: UUID) {
        guard hydrateTask == nil, readMetrics.policy.allows(.inventory) else { return }
        hydrateTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.connectionState.connectionID == owner else { return }
            self.hydrateTask = nil
            guard self.connectionState.connectionError == nil, !self.connectionState.isConnecting else { return }
            await self.poll(.inventory)
        }
    }
    private enum PollWait { case due, after(Double), paused }
    private func pollWait(_ kind: Poll, since last: Date?) -> PollWait {
        guard readMetrics.policy.allows(kind) else { return .paused }
        if kind == .inventory, sidebarInventoryDue, connectionState.connectionError == nil {
            return .due
        }
        if kind == .inventory, eventsCurrent, connectionState.connectionError == nil, let last {
            let interval = cadence.eventInventoryInterval
            let remaining = interval - now().timeIntervalSince(last)
            return remaining <= 0 ? .due : .after(remaining)
        }
        let retryIn = kind == .inventory ? connectionState.recovery.nextRetryAt?.timeIntervalSince(now()) : nil
        guard let delay = cadence.delay(kind, sinceLastPoll: last.map { .seconds(now().timeIntervalSince($0)) }, retryIn: retryIn) else { return .paused }
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        return seconds <= 0 ? .due : .after(seconds)
    }
    /// Retries scheduled outside the inventory loop (wake, network hints,
    /// reconnect) must not wait out a long background interval.
    private func observeRecovery(_ generation: UUID) {
        let retry = connectionState.recovery.nextRetryAt
        withObservationTracking { _ = connectionState.recovery.nextRetryAt } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == generation else { return }
                if self.connectionState.recovery.nextRetryAt != retry { self.schedule.wake() }
                self.observeRecovery(generation)
            }
        }
    }
    func handleNetworkHint() async { await poll(.inventory, networkHint: true) }
    private func poll(_ kind: Poll, networkHint: Bool = false) async {
        guard !Task.isCancelled, readMetrics.policy.allows(kind), scheduledReads[kind] == nil else { return }
        let context = ScheduledReadContext(generation: connectionState.connectionID, loop: kind, metrics: readMetrics, budget: selection.guestBudget)
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.readMetrics.policy.allows(kind) else { return }
            await GuestReadDiagnostics.$context.withValue(context) {
                await GuestReadDiagnostics.$scheduled.withValue(true) { await self.dispatchPoll(kind, networkHint: networkHint) }
            }
        }
        let owner = attempt
        scheduledReads[kind] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if attempt == owner { scheduledReads[kind] = nil }
    }
    private func dispatchPoll(_ kind: Poll, networkHint: Bool) async {
        guard !connectionState.isConnecting, !connectionState.recovery.isAttempting else { return }
        if networkHint { await retryConnection(includeDetails: false); return }
        if kind == .inventory, connectionState.recovery.nextRetryAt != nil {
            await retryConnection(automatically: true); return
        }
        guard connectionState.isConnected, connectionState.connectionError == nil else { return }
        switch kind {
        case .inventory: await refreshFromSidebar(includeDetails: false)
        case .details: await selection.reconcileDetails(cadence: cadence)
        case .approvals: await approvalStore.refreshApprovals(); advanceActivityClock()
        case .resources: await pools.refreshResources()
        case .usage:
            guard !Task.isCancelled, cadence.interval(.usage) != nil else { return }
            await refreshUsage()
        }
    }
    func stopPolling() {
        scheduledReads.values.forEach { $0.cancel() }
        scheduledReads.removeAll()
        attempt = UUID(); polling.forEach { $0.cancel() }; polling.removeAll()
    }
    deinit { hydrateTask?.cancel(); polling.forEach { $0.cancel() } }
    public func connect(client: any DiscoboxClient, label: String, demo: Bool = false) async {
        resetConnection()
        connectionState.begin(client: client, label: label, demo: demo)
        let current = connectionState.connectionID
        defer { if current == connectionState.connectionID, Task.isCancelled { disconnect() } }
        do {
            let project = try await connectionState.resolveProject()
            connectionState.accept(project)
            ensureEvents()
            catalog.acceptProject(project)
            prefetchCatalog(current)
            await refresh()
            guard connectionState.isCurrent(current) else { return }
            connectionState.finishInitialConnection()
        } catch {
            guard connectionState.isCurrent(current) else { return }
            connectionState.failed(error, now: now())
            connectionState.finishInitialConnection()
        }
    }
    private func prefetchCatalog(_ revision: UUID) {
        Task { [weak self] in
            guard let self, self.connectionState.connectionID == revision else { return }
            _ = try? await self.catalog.harnesses()
        }
    }

    // Share browse and keyboard refreshes per connection. A mutation still gets
    // its own post-write read so an earlier listing cannot acknowledge it.
    @ObservationIgnored private var sidebarRead: Task<Void, Never>?
    func refreshFromSidebar(includeDetails: Bool) async {
        guard connectionState.isConnected else { return }
        if connectionState.connectionError != nil {
            await retryConnection(includeDetails: includeDetails)
            return
        }
        let generation = connectionState.connectionID
        if let sidebarRead {
            await sidebarRead.value
        } else {
            let task = Task {
                guard connectionState.isCurrent(generation) else { return }
                await refreshConnected(includeDetails: false)
            }
            sidebarRead = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if generation == connectionState.connectionID { sidebarRead = nil }
        }
        if includeDetails, !Task.isCancelled, connectionState.isCurrent(generation), connectionState.connectionError == nil {
            await selection.refreshDetails()
        }
    }

    public func refresh() async { await refresh(includeDetails: true) }

    func refresh(includeDetails: Bool) async {
        guard connectionState.isConnected else { return }
        if connectionState.connectionError != nil && !connectionState.recoveryInFlight && !connectionState.isConnecting {
            await retryConnection(includeDetails: includeDetails); return
        }
        await refreshConnected(includeDetails: includeDetails)
    }

    private func refreshConnected(includeDetails: Bool) async {
        let current = connectionState.connectionID
        do {
            guard let request = try await inventory.refresh(using: connectionState, now: now), current == connectionState.connectionID else { return }
            connectionState.didRefresh()
            ensureEvents()
            advanceActivityClock()
            selection.reconcileInventory()
            if includeDetails { await selection.refreshDetails() }
            guard connectionState.isCurrent(current) else { return }
            inventory.complete(request, at: now())
        } catch {
            guard connectionState.isCurrent(current) else { return }
            connectionState.failed(error, now: now())
        }
    }

    public func reconnect() async {
        if connectionState.connectionError != nil || !connectionState.isConnected { await retryConnection(); return }
        guard let client = connectionState.detachClient() else { return }
        let label = connectionState.endpointLabel, demo = connectionState.isDemo, box = selection.sandboxID, terminal = selection.execID
        await connect(client: client, label: label, demo: demo)
        if connectionState.isConnected {
            await selection.selectBox(box)
            if let terminal, selection.execs.contains(where: { $0.id == terminal }) { await selection.selectExec(terminal) }
        }
    }

    public func retryConnection(automatically: Bool = false, includeDetails: Bool = true) async {
        guard let current = connectionState.beginRecovery(automatically: automatically, now: now()) else { return }
        let wasConnected = connectionState.isConnected
        defer { connectionState.finishRecovery(current, now: now()) }
        do {
            let project = try await connectionState.resolveProject()
            guard connectionState.isCurrent(current) else { return }
            if let projectID = connectionState.projectID, projectID != project.id {
                let label = connectionState.endpointLabel, demo = connectionState.isDemo
                guard let client = connectionState.detachClient() else { return }
                await connect(client: client, label: label, demo: demo)
                return
            }
            connectionState.accept(project)
            ensureEvents()
            catalog.acceptProject(project)
            await refresh(includeDetails: !automatically && includeDetails)
            guard connectionState.isCurrent(current) else { return }
            if connectionState.recovered(wasConnected: wasConnected) { prefetchCatalog(current) }
        } catch {
            guard connectionState.isCurrent(current) else { return }
            connectionState.failed(error, now: now())
        }
    }

    public func refreshUsage(force: Bool = false) async {
        guard let client = connectionState.client, let projectID = connectionState.projectID, connectionState.isConnected else { return }
        let connection = connectionState.connectionID
        let catalog = (try? await catalog.harnesses()) ?? catalog.cachedHarnesses
        guard connection == connectionState.connectionID, !Task.isCancelled else { return }
        await usage.refresh(client: client, project: projectID, boxes: inventory.sandboxes, configuredHarnesses: catalog, force: force)
    }

    public func disconnect() {
        stopPolling()
        resetConnection()
    }

    private func resetConnection() {
        sidebarRead?.cancel(); sidebarRead = nil; sidebarInventoryDue = false
        stopEvents()
        connectionState.invalidate()
        selection.reset()
        inventory.reset(); approvalStore.reset(); catalog.reset(); pools.reset(); pending.reset()
        usage = HarnessUsage(now: now)
        activityClock = ActivityClock(); reportDatesCache = nil
    }
}
