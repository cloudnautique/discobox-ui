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
    @ObservationIgnored var cadence = PollingCadence() { didSet { if cadence != oldValue { schedule.wake() } } }
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
                    await self?.poll(kind)
                    last = self?.now() ?? last
                }
            }
        }
        observeRecovery(attempt)
    }
    private enum PollWait { case due, after(Double), paused }
    private func pollWait(_ kind: Poll, since last: Date?) -> PollWait {
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
    private func poll(_ kind: Poll) async {
        guard !connectionState.isConnecting, !connectionState.recovery.isAttempting else { return }
        if kind == .inventory, connectionState.recovery.nextRetryAt != nil {
            await retryConnection(automatically: true); return
        }
        guard connectionState.isConnected, connectionState.connectionError == nil else { return }
        switch kind {
        case .inventory: await refresh()
        case .approvals: await approvalStore.refreshApprovals(); advanceActivityClock()
        case .resources: await pools.refreshResources()
        case .usage: await refreshUsage()
        }
    }
    func stopPolling() { attempt = UUID(); polling.forEach { $0.cancel() }; polling.removeAll() }
    deinit { polling.forEach { $0.cancel() } }
    public func connect(client: any DiscoboxClient, label: String, demo: Bool = false) async {
        resetConnection()
        connectionState.begin(client: client, label: label, demo: demo)
        let current = connectionState.revision
        defer { if current == connectionState.revision, Task.isCancelled { disconnect() } }
        do {
            let project = try await connectionState.resolveProject()
            connectionState.accept(project)
            catalog.acceptProject(project)
            prefetchCatalog(current)
            await refresh()
            guard current == connectionState.revision, !Task.isCancelled else { return }
            connectionState.finishInitialConnection()
        } catch {
            guard current == connectionState.revision, !Task.isCancelled else { return }
            connectionState.failed(error, now: now())
            connectionState.finishInitialConnection()
        }
    }
    private func prefetchCatalog(_ revision: UUID) {
        Task { [weak self] in
            guard let self, self.connectionState.revision == revision else { return }
            _ = try? await self.catalog.harnesses()
        }
    }

    public func refresh() async {
        guard connectionState.isConnected else { return }
        if connectionState.connectionError != nil && !connectionState.recoveryInFlight && !connectionState.isConnecting {
            await retryConnection(); return
        }
        let current = connectionState.revision
        do {
            guard let request = try await inventory.refresh(using: connectionState, now: now), current == connectionState.revision else { return }
            connectionState.didRefresh()
            advanceActivityClock()
            selection.reconcileInventory()
            await selection.refreshDetails()
            guard current == connectionState.revision, !Task.isCancelled else { return }
            inventory.complete(request, at: now())
        } catch {
            guard current == connectionState.revision, !Task.isCancelled else { return }
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

    public func retryConnection(automatically: Bool = false) async {
        guard let current = connectionState.beginRecovery(automatically: automatically, now: now()) else { return }
        let wasConnected = connectionState.isConnected
        defer { connectionState.finishRecovery(current, now: now()) }
        do {
            let project = try await connectionState.resolveProject()
            guard current == connectionState.revision, !Task.isCancelled else { return }
            if let projectID = connectionState.projectID, projectID != project.id {
                let label = connectionState.endpointLabel, demo = connectionState.isDemo
                guard let client = connectionState.detachClient() else { return }
                await connect(client: client, label: label, demo: demo)
                return
            }
            connectionState.accept(project)
            catalog.acceptProject(project)
            await refresh()
            guard current == connectionState.revision, !Task.isCancelled else { return }
            if connectionState.recovered(wasConnected: wasConnected) { prefetchCatalog(current) }
        } catch {
            guard current == connectionState.revision, !Task.isCancelled else { return }
            connectionState.failed(error, now: now())
        }
    }

    public func refreshUsage() async {
        guard let client = connectionState.client, let projectID = connectionState.projectID, connectionState.isConnected else { return }
        let connection = connectionState.connectionID
        let catalog = (try? await catalog.harnesses()) ?? catalog.cachedHarnesses
        guard connection == connectionState.connectionID, !Task.isCancelled else { return }
        await usage.refresh(client: client, project: projectID, boxes: inventory.sandboxes, configuredHarnesses: catalog)
    }

    public func disconnect() {
        stopPolling()
        resetConnection()
    }

    private func resetConnection() {
        connectionState.invalidate()
        selection.reset()
        inventory.reset(); approvalStore.reset(); catalog.reset(); pools.reset(); pending.reset()
        usage = HarnessUsage()
        activityClock = ActivityClock(); reportDatesCache = nil
    }
}
