import Foundation
import Observation

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
    @ObservationIgnored private let usageQueue = ScheduledUsageQueue()
    @ObservationIgnored private let guestBudget = GuestReadBudget()
    @ObservationIgnored private let preferences: UserDefaults?
    public var refreshPolicy: RefreshPolicy {
        didSet {
            if let data = try? JSONEncoder().encode(refreshPolicy) { preferences?.set(data, forKey: "discoboxRefreshPolicy") }
            for session in sessions { session.applyRefreshPolicy(refreshPolicy) }
        }
    }
    public private(set) var sessions: [ConnectionSession]
    public private(set) var activeID: String { didSet { if activeID != oldValue { updateCadence() } } }
    var creations: [BoxCreation] = []
    @ObservationIgnored private let pollingEnabled: Bool
    /// The most visible of the workspace windows' reports (see reportPresence).
    public var presence = PollingPresence.focused {
        didSet {
            guard presence != oldValue else { return }
            updateCadence()
            // Hidden windows poll slowly; re-age activity before it is seen again.
            if oldValue == .hidden { for host in sessions { host.advanceActivityClock() } }
        }
    }
    @ObservationIgnored private var presenceReports: [UUID: PollingPresence] = [:]
    @ObservationIgnored private var usageWindows: Set<UUID> = []
    public func reportUsageSurface(visible: Bool, from window: UUID) {
        if visible { usageWindows.insert(window) } else { usageWindows.remove(window) }
        updateCadence()
    }
    /// Each workspace window reports what it shows, from app activation and
    /// occlusion; polling follows the most visible. A closed window withdraws.
    public func reportPresence(_ value: PollingPresence, from window: UUID) {
        presenceReports[window] = value; presence = combinedPresence; updateCadence()
    }
    public func withdrawPresence(from window: UUID) {
        presenceReports[window] = nil; usageWindows.remove(window); presence = combinedPresence; updateCadence()
    }
    private var combinedPresence: PollingPresence {
        let reports = presenceReports.values
        return reports.contains(.focused) ? .focused : reports.contains(.visible) ? .visible : .hidden
    }
    public var active: ConnectionSession { sessions.first { $0.id == activeID } ?? sessions[0] }
    public var suggestedCreationComputerID: String {
        if let id = browser.computerID, session(id)?.connectionState.isConnected == true { return id }
        if active.connectionState.isConnected { return activeID }
        return sessions.first(where: { $0.connectionState.isConnected })?.id ?? activeID
    }
    public init(polling: Bool = true, now: @escaping () -> Date = Date.init, preferences: UserDefaults? = nil) {
        self.preferences = preferences
        refreshPolicy = preferences?.data(forKey: "discoboxRefreshPolicy").flatMap { try? JSONDecoder().decode(RefreshPolicy.self, from: $0) } ?? RefreshPolicy()
        let local = ConnectionSession(profile: .thisComputer, now: now)
        sessions = [local]; activeID = local.id; pollingEnabled = polling
        local.selection.guestBudget = guestBudget
        local.usageQueue = usageQueue
        local.applyRefreshPolicy(refreshPolicy)
        updateCadence()
    }
    public func session(_ id: String) -> ConnectionSession? { sessions.first { $0.id == id } }
    public func syncProfiles(_ profiles: [ConnectionProfile]) {
        for profile in profiles {
            let id = ConnectionProfiles.normalizedEndpoint(profile.endpoint)
            if let existing = session(id) { existing.update(profile) }
            else {
                let host = ConnectionSession(profile: profile)
                host.selection.guestBudget = guestBudget
                host.usageQueue = usageQueue
                host.applyRefreshPolicy(refreshPolicy)
                sessions.append(host)
            }
        }
        updateCadence()
    }
    private func updateCadence() {
        let usageVisible = usageWindows.contains { presenceReports[$0].map { $0 != .hidden } ?? false }
        for host in sessions { host.cadence = PollingCadence(presence: presence, isActiveHost: host.id == activeID, usageVisible: usageVisible) }
    }
    public func activate(_ id: String) {
        if session(id) != nil { activeID = id }
    }
    @discardableResult public func createBox(on id: String, harness: String, repository: String, prompt: String = "", poolID: String? = nil, connection: UUID? = nil, credentials: [LaunchCredential] = [], discoboxAPI: Bool = false) async throws -> Sandbox {
        guard let host = session(id), host.connectionState.isConnected else { throw DiscoboxError("Connect to the selected computer first.") }
        let generation = host.connectionState.connectionID
        let box = try await host.commands.createBox(harness: harness, repository: repository, prompt: prompt, poolID: poolID, connection: connection, credentials: credentials, discoboxAPI: discoboxAPI)
        guard host.connectionState.connectionID == generation, host.connectionState.isConnected else { throw CancellationError() }
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
        if host.connectionState.isConnected || host.connectionState.isConnecting {
            if host.connectionState.connectionError != nil { await host.retryConnection() }
            if select && host.connectionState.isConnected { activate(host.id) }
            return host
        }
        if host.connectionState.canReconnect {
            await host.retryConnection()
            if select && host.connectionState.isConnected { activate(host.id) }
            return host
        }
        let attempt = host.beginConnection()
        let transport = try client()
        await host.connect(client: transport, label: host.id, demo: demo)
        guard host.ownsAttempt(attempt), !Task.isCancelled else { return host }
        // Failed initial connects need the recovery loop just as much as
        // connections that drop after their first successful inventory.
        if pollingEnabled { host.startPolling() }
        if host.connectionState.isConnected {
            if select { activate(host.id) }
        }
        return host
    }
    public func selectBox(_ location: BoxLocation) async {
        guard let host = session(location.connection), host.connectionState.isConnected,
              let box = host.inventory.sandboxes.first(where: { $0.id == location.box }) else { return }
        if browser.filter == .archived {
            if box.isArchived {
                if !browser.archivedSelection.contains(location) { browser.selectArchives([location]) }
            }
            else if creationPins.contains(where: { $0.id == location }) { browser.archivedSelection.removeAll() }
            else { browser.filter = .all; browser.archivedSelection.removeAll() }
        }
        activate(host.id)
        if browser.filter != .archived, !browser.selectedBoxes.contains(location) { browser.selectBoxes([location]) }
        await host.selection.selectBox(location.box)
    }
    public func disconnect(_ id: String) {
        guard let host = session(id) else { return }
        host.stopPolling(); host.disconnect()
        creations.removeAll { $0.id.connection == id }
    }
    public func disconnectAll() { for host in sessions { disconnect(host.id) } }
    public func retryInterruptedConnections(probeHealthy: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for host in sessions where host.connectionState.canReconnect && (probeHealthy || host.connectionState.connectionError != nil) && !host.connectionState.recovery.requiresAction {
                let workspace = host
                group.addTask { await workspace.handleNetworkHint() }
            }
        }
    }
    /// Every connected box with its activity, power and title derived once per
    /// input change (see BoxBrowser.fleet); the browser's selectors consume it.
    public var qualifiedBoxes: [ConnectedBox] { browserFleet.items }
    public var switcherBoxes: [ConnectedBox] { browser.switcherBoxes(in: qualifiedBoxes) }
}
