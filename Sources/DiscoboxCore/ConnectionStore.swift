import Foundation
import Observation

@MainActor @Observable
public final class ConnectionStore {
    public private(set) var connectionID = UUID()
    public private(set) var projectID: String?
    public private(set) var isConnected = false { didSet { if isConnected != oldValue { lifecycle(.connectivityChanged) } } }
    public private(set) var isConnecting = false
    public private(set) var isDemo = false
    public private(set) var endpointLabel = ""
    public private(set) var transportEndpoint = ""
    public private(set) var connectionError: String?
    /// The kind of `connectionError`, so views never match on its text.
    public private(set) var connectionErrorKind: DiscoboxError.Kind?
    public private(set) var recovery = ConnectionRecovery()
    public private(set) var recoveryCount = 0
    @ObservationIgnored var client: (any DiscoboxClient)?
    @ObservationIgnored var recoveryInFlight = false
    /// Lifecycle transitions, wired by ConnectionSession (see ConnectionLifecycleEvent).
    @ObservationIgnored var lifecycle: @MainActor (ConnectionLifecycleEvent) -> Void = { _ in }
    public var canReconnect: Bool { client != nil }
    /// True while `generation` (a captured connectionID) is still this
    /// connection's lifetime and the calling task has not been cancelled.
    func isCurrent(_ generation: UUID) -> Bool { generation == connectionID && !Task.isCancelled }
    public init() {}
    func invalidate(closeTransport: Bool = true) {
        connectionID = UUID()
        if closeTransport { client?.closeConnection() }
        client = nil; projectID = nil; transportEndpoint = ""
        isConnected = false; isConnecting = false; isDemo = false
        connectionError = nil; connectionErrorKind = nil; recovery.reset(); recoveryInFlight = false; recoveryCount = 0
    }
    func begin(client: any DiscoboxClient, label: String, demo: Bool) {
        self.client = client; endpointLabel = label; transportEndpoint = label
        isDemo = demo; isConnecting = true
    }
    func resolveProject() async throws -> Project {
        guard let client else { throw DiscoboxError("Connect to a server first.") }
        let current = connectionID
        try await prepareTransport()
        let project = try await client.decode(.init(.defaultProject), as: Project.self)
        guard isCurrent(current) else { throw CancellationError() }
        return project
    }
    func accept(_ project: Project) { projectID = project.id; isConnected = true }
    func finishInitialConnection() { isConnecting = false; if connectionError != nil { isConnected = false } }
    func detachClient() -> (any DiscoboxClient)? {
        let previous = client; client = nil; return previous
    }
    func beginRecovery(automatically: Bool, now: Date) -> UUID? {
        guard client != nil, !isConnecting, !recoveryInFlight else { return nil }
        if automatically {
            guard let deadline = recovery.nextRetryAt, deadline <= now, !recovery.requiresAction else { return nil }
        }
        recoveryInFlight = true; recovery.begin(); return connectionID
    }
    func finishRecovery(_ token: UUID, now: Date) {
        guard token == connectionID else { return }
        recoveryInFlight = false
        if Task.isCancelled, recovery.isAttempting { failed(URLError(.networkConnectionLost), now: now) }
    }
    func recovered(wasConnected: Bool) -> Bool {
        if connectionError == nil { recovery.reset(); recoveryCount += 1; return true }
        if !wasConnected { isConnected = false }
        return false
    }
    func prepareTransport() async throws {
        guard let client else { throw DiscoboxError("Connect to a server first.") }
        let current = connectionID
        let endpoint = try await client.prepareConnection()
        guard isCurrent(current) else { throw CancellationError() }
        if let endpoint, endpoint != transportEndpoint {
            let previous = transportEndpoint
            transportEndpoint = endpoint
            if !previous.isEmpty { lifecycle(.transportReplaced(previous: previous)) }
        }
    }
    func didRefresh() {
        connectionError = nil; connectionErrorKind = nil
        if !recoveryInFlight { recovery.reset() }
    }
    func failed(_ error: Error, now: Date) {
        connectionError = error.localizedDescription
        connectionErrorKind = (error as? DiscoboxError)?.kind ?? (ConnectionRecovery.canRetry(error) ? .transport : .other)
        recovery.failed(error, now: now)
    }
    func capture() throws -> SessionAccess {
        guard let client, let projectID else { throw DiscoboxError("Connect to a server first.") }
        return SessionAccess(client: client, scope: .init(generation: connectionID, project: projectID), owner: self)
    }
}
