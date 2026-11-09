import Foundation
import Testing
@testable import DiscoboxCore

@Test func connectionBackoffIsBoundedAndResetsAfterRecovery() {
    var recovery = ConnectionRecovery()
    let now = Date(timeIntervalSince1970: 100)
    for delay in [2.0, 4, 8, 16, 30, 30, 30] {
        recovery.begin()
        #expect(recovery.isAttempting)
        recovery.failed(URLError(.cannotConnectToHost), now: now, jitter: 1)
        #expect(recovery.nextRetryAt == now.addingTimeInterval(delay))
        #expect(!recovery.isAttempting && !recovery.requiresAction)
    }
    recovery.reset()
    #expect(recovery == ConnectionRecovery())
}

@Test func connectionRecoveryDistinguishesNetworkFailuresFromRequiredUserActions() {
    for error in [URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.dnsLookupFailed)] {
        #expect(ConnectionRecovery.canRetry(error))
    }
    for error: Error in [URLError(.serverCertificateUntrusted), DiscoboxError("Access refused (403)"), DiscoboxError("Unsupported companion protocol version."), CancellationError()] {
        var recovery = ConnectionRecovery()
        recovery.failed(error, now: .now)
        #expect(recovery.requiresAction && recovery.nextRetryAt == nil)
    }
    #expect(ConnectionRecovery.canRetry(DiscoboxError("HTTP 502", connectionRetryable: true)))
}

@MainActor @Test func transientRecoveryKeepsTheBoxSelectionAndOtherComputerAlive() async throws {
    let hub = Connections(polling: false), a = RecoveryFixture(), b = RecoveryFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { a }
    let remote = try await hub.connect(.init(name: "Remote", endpoint: "https://remote.example.invalid"), demo: true) { b }
    defer { hub.disconnectAll() }
    await hub.selectBox(.init(connection: remote.id, box: "demo-ui"))
    hub.browser.filter = .running; hub.browser.searchText = "keep this"
    let generation = remote.workspace.connectionID, selection = remote.workspace.execID
    let boxes = remote.workspace.sandboxes
    await b.setOnline(false); await remote.workspace.refresh()
    #expect(remote.workspace.connectionError != nil && remote.workspace.recovery.nextRetryAt != nil)
    #expect(remote.workspace.isConnected && remote.workspace.sandboxes == boxes)
    let probes = await b.count(.defaultProject)
    await remote.workspace.retryConnection(automatically: true)
    #expect(await b.count(.defaultProject) == probes)
    await b.setOnline(true); await remote.workspace.retryConnection()
    #expect(remote.workspace.connectionError == nil && remote.workspace.recovery == ConnectionRecovery())
    #expect(remote.workspace.connectionID == generation && remote.workspace.sandboxID == "demo-ui" && remote.workspace.execID == selection)
    #expect(remote.workspace.recoveryCount == 1 && b.lifetime.closes == 0)
    #expect(hub.browser.filter == .running && hub.browser.searchText == "keep this" && hub.active === remote)
    #expect(local.workspace.isConnected && a.lifetime.closes == 0)
}

@MainActor @Test func initiallyUnreachableHostRetriesWithoutAnotherConnectClick() async throws {
    let hub = Connections(), client = RecoveryFixture()
    await client.setOnline(false)
    let host = try await hub.connect(.thisComputer) { client }
    defer { hub.disconnectAll() }
    #expect(!host.workspace.isConnected && host.workspace.recovery.nextRetryAt != nil)
    await client.setOnline(true)
    for _ in 0..<100 {
        if host.workspace.isConnected && !host.workspace.recovery.isAttempting { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(host.workspace.isConnected && host.workspace.connectionError == nil)
    #expect(!host.workspace.sandboxes.isEmpty && host.workspace.recoveryCount == 1)
}

@MainActor @Test func recoveryIsSingleFlightAndDisconnectIgnoresItsLateCompletion() async throws {
    let workspace = Workspace(), client = RecoveryFixture()
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    await client.setOnline(false); await workspace.refresh()
    await client.setOnline(true); await client.blockNextProbe()
    let pending = Task { await workspace.retryConnection() }
    await client.waitForProbe()
    await workspace.retryConnection()
    #expect(await client.count(.defaultProject) == 2)
    workspace.disconnect()
    await client.releaseProbe(); await pending.value
    #expect(!workspace.isConnected && !workspace.canReconnect && workspace.sandboxes.isEmpty)
    #expect(workspace.recovery == ConnectionRecovery() && client.lifetime.closes == 1)
}

@MainActor @Test func recoveryNeverReplaysAnAmbiguousApproval() async throws {
    let workspace = Workspace(), client = RecoveryFixture()
    await workspace.connect(client: client, label: "fixture")
    await workspace.refreshApprovals()
    let item = try #require(workspace.approvals.first)
    do { try await workspace.answer(item, action: "deny", payload: .object([:])); Issue.record("Lost response accepted") } catch { }
    await client.setOnline(false); await workspace.refresh()
    await client.setOnline(true); await workspace.retryConnection()
    #expect(await client.count(.answer) == 1)
    #expect(workspace.connectionError == nil)
    workspace.disconnect()
}

@MainActor @Test func changedDefaultProjectInvalidatesOldConfirmationsDuringRecovery() async throws {
    let workspace = Workspace(), client = RecoveryFixture()
    await workspace.connect(client: client, label: "fixture")
    await workspace.selectBox("demo-ui")
    let generation = workspace.connectionID
    await client.setOnline(false); await workspace.refresh()
    await client.changeProject(); await client.setOnline(true); await workspace.retryConnection()
    #expect(workspace.isConnected && workspace.projectID == "replacement-project")
    #expect(workspace.connectionID != generation && workspace.sandboxID == nil)
    workspace.disconnect()
}

@MainActor @Test func networkHintsDoNotReopenDisconnectedHostsOrRetryAuthorizationFailures() async throws {
    let hub = Connections(polling: false), a = RecoveryFixture(), b = RecoveryFixture()
    let local = try await hub.connect(.thisComputer) { a }
    let remote = try await hub.connect(.init(name: "Remote", endpoint: "https://remote.example.invalid")) { b }
    defer { hub.disconnectAll() }
    hub.disconnect(local.id)
    await b.denyAccess(); await remote.workspace.refresh()
    #expect(remote.workspace.recovery.requiresAction)
    await hub.retryInterruptedConnections(probeHealthy: true)
    #expect(!local.workspace.canReconnect && !local.workspace.isConnected)
    #expect(await a.count(.defaultProject) == 1)
    #expect(await b.count(.defaultProject) == 1)
}

@MainActor @Test func cancelledProbeCanBeRetriedInsteadOfGettingStuckConnecting() async throws {
    let workspace = Workspace(), client = RecoveryFixture()
    await workspace.connect(client: client, label: "fixture")
    await client.setOnline(false); await workspace.refresh()
    await client.setOnline(true); await client.blockNextProbe()
    let pending = Task { await workspace.retryConnection() }
    await client.waitForProbe(); pending.cancel()
    await client.releaseProbe(); await pending.value
    #expect(!workspace.recovery.isAttempting && workspace.recovery.nextRetryAt != nil)
    await workspace.retryConnection()
    #expect(workspace.connectionError == nil)
    workspace.disconnect()
}

@MainActor @Test func cancellingAnInitialConnectClosesTheClientAndDoesNotScheduleRetries() async throws {
    let hub = Connections(), client = RecoveryFixture()
    await client.blockNextProbe()
    let pending = Task { try await hub.connect(.thisComputer) { client } }
    await client.waitForProbe(); pending.cancel()
    await client.releaseProbe()
    let host = try await pending.value
    #expect(!host.workspace.canReconnect && !host.workspace.isConnecting && !host.workspace.isConnected)
    #expect(host.workspace.recovery.nextRetryAt == nil && client.lifetime.closes == 1)
    await hub.retryInterruptedConnections(probeHealthy: true)
    #expect(await client.count(.defaultProject) == 1)
    hub.disconnectAll()
}

private final class RecoveryLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var closes: Int { lock.withLock { value } }
    func close() { lock.withLock { value += 1 } }
}
private actor RecoveryFixture: DiscoboxClient {
    private let demo = DemoClient(pendingRequests: true)
    nonisolated let lifetime = RecoveryLifetime()
    private var online = true
    private var denied = false
    private var replacement = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var requests: [BridgeRequest.Operation] = []
    nonisolated func closeConnection() { lifetime.close() }
    func setOnline(_ value: Bool) { online = value }
    func denyAccess() { denied = true }
    func changeProject() { replacement = true }
    func blockNextProbe() { blocked = true }
    func waitForProbe() async { while continuation == nil { await Task.yield() } }
    func releaseProbe() { blocked = false; continuation?.resume(); continuation = nil }
    func count(_ operation: BridgeRequest.Operation) -> Int { requests.filter { $0 == operation }.count }
    func perform(_ request: BridgeRequest) async throws -> Data {
        requests.append(request.operation)
        guard online else { throw URLError(.notConnectedToInternet) }
        guard !denied else { throw DiscoboxError("Access refused (403)") }
        if request.operation == .defaultProject, blocked { await withCheckedContinuation { continuation = $0 } }
        if request.operation == .defaultProject, replacement { return Data(#"{"id":"replacement-project","name":"Replacement"}"#.utf8) }
        if request.operation == .answer { throw URLError(.networkConnectionLost) }
        return try await demo.perform(request)
    }
}
