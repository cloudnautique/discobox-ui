import Foundation
import Observation

@MainActor @Observable public final class ConnectionSession: Identifiable {
    public let id: String
    public private(set) var profile: ConnectionProfile
    public let workspace = Workspace()
    @ObservationIgnored private var polling: [Task<Void, Never>] = []
    @ObservationIgnored private var attempt = UUID()
    @ObservationIgnored private let schedule: PollingSchedule
    var cadence: PollingCadence { get { schedule.cadence } set { schedule.cadence = newValue } }
    func beginConnection() -> UUID { stopPolling(); return attempt }
    func ownsAttempt(_ value: UUID) -> Bool { attempt == value }
    public init(profile: ConnectionProfile, clock: PollingClock = .continuous) {
        self.profile = profile
        id = ConnectionProfiles.normalizedEndpoint(profile.endpoint)
        schedule = PollingSchedule(clock: clock)
        workspace.streamsLiveTerminals = true
    }
    public func update(_ profile: ConnectionProfile) { self.profile = profile }
    func startPolling() {
        stopPolling()
        let workspace = workspace
        polling = [Self.poll(.inventory, workspace: workspace, schedule: schedule, immediately: false) {
            if workspace.isConnecting || workspace.recovery.isAttempting { return }
            if workspace.recovery.nextRetryAt != nil { await workspace.retryConnection(automatically: true) }
            else if workspace.isConnected && workspace.connectionError == nil { await workspace.refresh() }
        }, Self.poll(.approvals, workspace: workspace, schedule: schedule) {
            if Self.isReady(workspace) { await workspace.refreshApprovals() }
        }, Self.poll(.resources, workspace: workspace, schedule: schedule, priority: .utility) {
            if Self.isReady(workspace) { await workspace.refreshResources() }
        }, Self.poll(.usage, workspace: workspace, schedule: schedule, priority: .utility) {
            if Self.isReady(workspace) { await workspace.refreshUsage() }
        }]
        observeRecovery(attempt)
    }
    private static func isReady(_ workspace: Workspace) -> Bool {
        workspace.isConnected && workspace.connectionError == nil && !workspace.isConnecting && !workspace.recovery.isAttempting
    }
    /// A wake only recomputes the deadline from the last poll, so lowering the
    /// cadence never adds a poll and raising it polls as soon as one is due.
    private static func poll(_ loop: PollingLoop, workspace: Workspace, schedule: PollingSchedule, priority: TaskPriority? = nil,
                             immediately: Bool = true, work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        Task(priority: priority) { @MainActor in
            var last = immediately ? nil : schedule.clock.now()
            while !Task.isCancelled {
                do {
                    while true {
                        let retryIn = loop == .inventory ? workspace.recovery.nextRetryAt?.timeIntervalSinceNow : nil
                        let delay = schedule.cadence.delay(loop, sinceLastPoll: last.map { schedule.clock.now() - $0 }, retryIn: retryIn)
                        if let delay, delay <= .zero { break }
                        if try await !schedule.sleep(for: delay) { break }
                    }
                } catch { return }
                await work()
                last = schedule.clock.now()
            }
        }
    }
    /// Retries scheduled outside the inventory loop (wake, network hints,
    /// reconnect) must not wait out a long background interval.
    private func observeRecovery(_ generation: UUID) {
        let retry = workspace.recovery.nextRetryAt
        withObservationTracking { _ = workspace.recovery.nextRetryAt } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == generation else { return }
                if self.workspace.recovery.nextRetryAt != retry { self.schedule.wake() }
                self.observeRecovery(generation)
            }
        }
    }
    func stopPolling() { attempt = UUID(); polling.forEach { $0.cancel() }; polling.removeAll() }
    deinit { polling.forEach { $0.cancel() } }
}

public struct BoxLocation: Hashable, Sendable {
    public let connection: String
    public let box: String
    public init(connection: String, box: String) { self.connection = connection; self.box = box }
}
public struct ConnectedBox: Identifiable, Sendable, Equatable {
    public var id: BoxLocation { location }
    public let location: BoxLocation
    public let computer: String
    public let box: Sandbox
    public let needsAttention: Bool
    public let activity: AgentActivity?
    public let power: BoxPowerStatus
    /// `Sandbox.sidebarTitle`, derived once because sorting compares it repeatedly.
    public let title: String
    public init(location: BoxLocation, computer: String, box: Sandbox, needsAttention: Bool, activity: AgentActivity? = nil, power: BoxPowerStatus? = nil, title: String? = nil) {
        self.location = location; self.computer = computer; self.box = box; self.needsAttention = needsAttention; self.activity = activity
        self.power = power ?? BoxPowerStatus(box: box)
        self.title = title ?? box.sidebarTitle
    }
    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            computer.localizedCaseInsensitiveContains($0) || box.matchesSearch(String($0))
        }
    }
}

/// Active selection never owns the transports: every computer keeps its own
/// workspace, client, caches, polling and connection generation while hidden.
@MainActor @Observable public final class Connections {
    public let browser = BoxBrowser()
    public private(set) var sessions: [ConnectionSession]
    public private(set) var activeID: String { didSet { if activeID != oldValue { updateCadence() } } }
    var creations: [BoxCreation] = []
    @ObservationIgnored private let pollingEnabled: Bool
    @ObservationIgnored private let clock: PollingClock
    /// The most visible of the workspace windows' reports (see reportPresence).
    public var presence = PollingPresence.focused {
        didSet {
            guard presence != oldValue else { return }
            updateCadence()
            // Hidden windows poll slowly; re-age activity before it is seen again.
            if oldValue == .hidden { for host in sessions { host.workspace.advanceActivityClock() } }
        }
    }
    @ObservationIgnored private var presenceReports: [UUID: PollingPresence] = [:]
    /// Each workspace window reports what it shows, from app activation and
    /// occlusion; polling follows the most visible. A closed window withdraws.
    public func reportPresence(_ value: PollingPresence, from window: UUID) {
        presenceReports[window] = value; presence = combinedPresence
    }
    public func withdrawPresence(from window: UUID) {
        presenceReports[window] = nil; presence = combinedPresence
    }
    private var combinedPresence: PollingPresence {
        let reports = presenceReports.values
        return reports.contains(.focused) ? .focused : reports.contains(.visible) ? .visible : .hidden
    }
    public var active: ConnectionSession { sessions.first { $0.id == activeID } ?? sessions[0] }
    public var suggestedCreationComputerID: String {
        if let id = browser.computerID, session(id)?.workspace.isConnected == true { return id }
        if active.workspace.isConnected { return activeID }
        return sessions.first(where: { $0.workspace.isConnected })?.id ?? activeID
    }
    public init(polling: Bool = true, clock: PollingClock = .continuous) {
        let local = ConnectionSession(profile: .thisComputer, clock: clock)
        sessions = [local]; activeID = local.id; pollingEnabled = polling; self.clock = clock
        updateCadence()
    }
    public func session(_ id: String) -> ConnectionSession? { sessions.first { $0.id == id } }
    public func syncProfiles(_ profiles: [ConnectionProfile]) {
        for profile in profiles {
            let id = ConnectionProfiles.normalizedEndpoint(profile.endpoint)
            if let existing = session(id) { existing.update(profile) }
            else { sessions.append(ConnectionSession(profile: profile, clock: clock)) }
        }
        updateCadence()
    }
    private func updateCadence() {
        for host in sessions { host.cadence = PollingCadence(presence: presence, isActiveHost: host.id == activeID) }
    }
    public func activate(_ id: String) {
        if session(id) != nil { activeID = id }
    }
    @discardableResult public func createBox(on id: String, harness: String, repository: String, prompt: String = "", poolID: String? = nil, connection: UUID? = nil, credentials: [LaunchCredential] = [], discoboxAPI: Bool = false) async throws -> Sandbox {
        guard let host = session(id), host.workspace.isConnected else { throw DiscoboxError("Connect to the selected computer first.") }
        let generation = host.workspace.connectionID
        let box = try await host.workspace.createBox(harness: harness, repository: repository, prompt: prompt, poolID: poolID, connection: connection, credentials: credentials, discoboxAPI: discoboxAPI)
        guard host.workspace.connectionID == generation, host.workspace.isConnected else { throw CancellationError() }
        let location = BoxLocation(connection: host.id, box: box.id)
        creations.append(.init(connection: generation, item: .init(location: location, computer: host.profile.displayName, box: box, needsAttention: box.matchesAttention)))
        browser.archivedSelection.removeAll()
        activate(host.id)
        browser.requestReveal(location)
        reconcileCreations()
        return box
    }
    @discardableResult public func connect(_ profile: ConnectionProfile, demo: Bool = false, select: Bool = true, client: () throws -> any DiscoboxClient) async throws -> ConnectionSession {
        syncProfiles([profile])
        let host = session(ConnectionProfiles.normalizedEndpoint(profile.endpoint))!
        if host.workspace.isConnected || host.workspace.isConnecting {
            if host.workspace.connectionError != nil { await host.workspace.retryConnection() }
            if select && host.workspace.isConnected { activate(host.id) }
            return host
        }
        if host.workspace.canReconnect {
            await host.workspace.retryConnection()
            if select && host.workspace.isConnected { activate(host.id) }
            return host
        }
        let attempt = host.beginConnection()
        let transport = try client()
        await host.workspace.connect(client: transport, label: host.id, demo: demo)
        guard host.ownsAttempt(attempt), !Task.isCancelled else { return host }
        // Failed initial connects need the recovery loop just as much as
        // connections that drop after their first successful inventory.
        if pollingEnabled { host.startPolling() }
        if host.workspace.isConnected {
            if select { activate(host.id) }
        }
        return host
    }
    public func selectBox(_ location: BoxLocation) async {
        guard let host = session(location.connection), host.workspace.isConnected,
              let box = host.workspace.sandboxes.first(where: { $0.id == location.box }) else { return }
        if browser.filter == .archived {
            if box.isArchived {
                if !browser.archivedSelection.contains(location) { browser.selectArchives([location]) }
            }
            else if creationPins.contains(where: { $0.id == location }) { browser.archivedSelection.removeAll() }
            else { browser.filter = .all; browser.archivedSelection.removeAll() }
        }
        activate(host.id)
        if browser.filter != .archived, !browser.selectedBoxes.contains(location) { browser.selectBoxes([location]) }
        await host.workspace.selectBox(location.box)
    }
    public func disconnect(_ id: String) {
        guard let host = session(id) else { return }
        host.stopPolling(); host.workspace.disconnect()
        creations.removeAll { $0.id.connection == id }
    }
    public func disconnectAll() { for host in sessions { disconnect(host.id) } }
    public func retryInterruptedConnections(probeHealthy: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for host in sessions where host.workspace.canReconnect && (probeHealthy || host.workspace.connectionError != nil) && !host.workspace.recovery.requiresAction {
                let workspace = host.workspace
                group.addTask { await workspace.retryConnection() }
            }
        }
    }
    public var switcherBoxes: [ConnectedBox] { browserFleet.switcherOrder }
}
