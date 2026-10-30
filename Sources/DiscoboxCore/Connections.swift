import Foundation
import Observation

@MainActor @Observable public final class ConnectionSession: Identifiable {
    public let id: String
    public private(set) var profile: ConnectionProfile
    public let workspace = Workspace()
    @ObservationIgnored private var polling: [Task<Void, Never>] = []
    public init(profile: ConnectionProfile) {
        self.profile = profile
        id = ConnectionProfiles.normalizedEndpoint(profile.endpoint)
        workspace.streamsLiveTerminals = true
    }
    public func update(_ profile: ConnectionProfile) { self.profile = profile }
    func startPolling() {
        stopPolling()
        let workspace = workspace
        polling = [Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if workspace.isConnected { await workspace.refresh() }
            }
        }, Task {
            while !Task.isCancelled {
                if workspace.isConnected { await workspace.refreshApprovals() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }, Task(priority: .utility) {
            while !Task.isCancelled {
                if workspace.isConnected { await workspace.refreshResources() }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }, Task(priority: .utility) {
            while !Task.isCancelled {
                if workspace.isConnected { await workspace.refreshUsage() }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }]
    }
    func stopPolling() { polling.forEach { $0.cancel() }; polling.removeAll() }
    deinit { polling.forEach { $0.cancel() } }
}

public struct BoxLocation: Hashable, Sendable {
    public let connection: String
    public let box: String
    public init(connection: String, box: String) { self.connection = connection; self.box = box }
}
public struct ConnectedBox: Identifiable, Sendable {
    public var id: BoxLocation { location }
    public let location: BoxLocation
    public let computer: String
    public let box: Sandbox
    public let needsAttention: Bool
    public init(location: BoxLocation, computer: String, box: Sandbox, needsAttention: Bool) {
        self.location = location; self.computer = computer; self.box = box; self.needsAttention = needsAttention
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
    public private(set) var activeID: String
    @ObservationIgnored private let pollingEnabled: Bool
    public var active: ConnectionSession { sessions.first { $0.id == activeID } ?? sessions[0] }
    public var suggestedCreationComputerID: String {
        if let id = browser.computerID, session(id)?.workspace.isConnected == true { return id }
        if active.workspace.isConnected { return activeID }
        return sessions.first(where: { $0.workspace.isConnected })?.id ?? activeID
    }
    public init(polling: Bool = true) {
        let local = ConnectionSession(profile: .thisComputer)
        sessions = [local]; activeID = local.id; pollingEnabled = polling
    }
    public func session(_ id: String) -> ConnectionSession? { sessions.first { $0.id == id } }
    public func syncProfiles(_ profiles: [ConnectionProfile]) {
        for profile in profiles {
            let id = ConnectionProfiles.normalizedEndpoint(profile.endpoint)
            if let existing = session(id) { existing.update(profile) }
            else { sessions.append(ConnectionSession(profile: profile)) }
        }
    }
    public func activate(_ id: String) {
        if session(id) != nil { activeID = id }
    }
    public func createBox(on id: String, harness: String, repository: String, prompt: String = "", poolID: String? = nil, connection: UUID? = nil) async throws {
        guard let host = session(id), host.workspace.isConnected else { throw DiscoboxError("Connect to the selected computer first.") }
        let generation = host.workspace.connectionID
        try await host.workspace.createBox(harness: harness, repository: repository, prompt: prompt, poolID: poolID, connection: connection)
        guard host.workspace.connectionID == generation, host.workspace.isConnected else { throw CancellationError() }
        browser.filter = .all; browser.searchText = ""; browser.selectedTags.removeAll(); browser.archivedSelection.removeAll()
        if browser.computerID != nil { browser.computerID = host.id }
        activate(host.id)
    }
    @discardableResult public func connect(_ profile: ConnectionProfile, demo: Bool = false, select: Bool = true, client: () throws -> any DiscoboxClient) async throws -> ConnectionSession {
        syncProfiles([profile])
        let host = session(ConnectionProfiles.normalizedEndpoint(profile.endpoint))!
        if host.workspace.isConnected || host.workspace.isConnecting {
            if select && host.workspace.isConnected { activate(host.id) }
            return host
        }
        let transport = try client()
        await host.workspace.connect(client: transport, label: host.id, demo: demo)
        if host.workspace.isConnected {
            if pollingEnabled { host.startPolling() }
            if select { activate(host.id) }
        }
        return host
    }
    public func selectBox(_ location: BoxLocation) async {
        guard let host = session(location.connection), host.workspace.isConnected,
              let box = host.workspace.sandboxes.first(where: { $0.id == location.box }) else { return }
        if browser.filter == .archived {
            if box.isArchived { browser.selectArchives([location]) }
            else { browser.filter = .all; browser.archivedSelection.removeAll() }
        }
        activate(host.id)
        await host.workspace.selectBox(location.box)
    }
    public func disconnect(_ id: String) {
        guard let host = session(id) else { return }
        host.stopPolling(); host.workspace.disconnect()
    }
    public func disconnectAll() { for host in sessions { disconnect(host.id) } }
    public var switcherBoxes: [ConnectedBox] {
        sessions.filter { $0.workspace.isConnected }.flatMap { host in
            let waiting = Set(host.workspace.approvals.map(\.boxID))
            return host.workspace.switcherBoxes.map { box in
                ConnectedBox(location: .init(connection: host.id, box: box.id), computer: host.profile.displayName, box: box,
                             needsAttention: box.matchesAttention || waiting.contains(box.id))
            }
        }.sorted {
            func rank(_ item: ConnectedBox) -> Int { item.needsAttention ? 0 : item.box.isRunning ? 1 : 2 }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            let names = $0.box.displayName.localizedStandardCompare($1.box.displayName)
            if names != .orderedSame { return names == .orderedAscending }
            if $0.computer != $1.computer { return $0.computer.localizedStandardCompare($1.computer) == .orderedAscending }
            return $0.location.connection < $1.location.connection
        }
    }
}
