import Foundation
import Testing
@testable import DiscoboxCore

private final class ClientLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var closes: Int { lock.withLock { value } }
    func close() { lock.withLock { value += 1 } }
}
private actor HostFixture: DiscoboxClient {
    let demo: DemoClient
    nonisolated let lifetime = ClientLifetime()
    let fail: Bool
    let failCreation: Bool
    var requests: [BridgeRequest] = []
    init(fail: Bool = false, pending: Bool = false, failCreation: Bool = false) { self.fail = fail; self.failCreation = failCreation; demo = DemoClient(pendingRequests: pending) }
    nonisolated func closeConnection() { lifetime.close() }
    func perform(_ request: BridgeRequest) async throws -> Data {
        requests.append(request)
        if fail { throw DiscoboxError("Fixture computer unavailable") }
        if failCreation && request.operation == .createBox { throw DiscoboxError("Fixture creation failed") }
        return try await demo.perform(request)
    }
    func count(_ operation: BridgeRequest.Operation) -> Int { requests.filter { $0.operation == operation }.count }
    func creationPayload() -> JSONValue? { requests.first { $0.operation == .createBox }?.payload }
}

@MainActor @Test func launchCredentialsOnlyReachTheChosenComputerAndCreation() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    _ = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    let credential = LaunchCredential(environment: "OBOT_MCP_TOKEN", host: "example.test", value: "fixture-only-token")
    try await connections.createBox(on: remote.id, harness: "demo-harness", repository: "", credentials: [credential])
    let expected = try LaunchCredential.payload([credential])
    #expect(await localClient.creationPayload() == nil)
    #expect(await remoteClient.creationPayload() == expected)
    #expect(await remoteClient.count(.createBox) == 1)
    connections.disconnectAll()
}

@MainActor @Test func remoteCreationPreservesArchivedAndSelectsTheDestinationComputer() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    connections.browser.filter = .archived
    connections.browser.searchText = "old query"
    connections.browser.filter = .archived
    connections.activate(local.id)
    try await connections.createBox(on: remote.id, harness: "demo-harness", repository: "", prompt: "Fixture task")
    #expect(connections.active === remote)
    #expect(connections.browser.filter == .archived)
    #expect(connections.browser.searchText == "old query")
    #expect(remote.selection.selectedBox?.displayName == "New demo box")
    #expect(!connections.browserBoxes.contains { $0.location.box == remote.selection.sandboxID })
    #expect(connections.browser.filter == .archived)
    #expect(connections.creationPins.contains { $0.id.connection == remote.id && $0.id.box == remote.selection.sandboxID })
    #expect(await remoteClient.count(.createBox) == 1)
    #expect(await localClient.count(.createBox) == 0)
    connections.disconnectAll()
}

@MainActor @Test func failedRemoteCreationPreservesTheCurrentComputerAndFilters() async throws {
    let connections = Connections(polling: false)
    let local = try await connections.connect(.thisComputer, demo: true) { HostFixture() }
    let remote = try await connections.connect(studioProfile, demo: true) { HostFixture(failCreation: true) }
    connections.browser.filter = .archived
    connections.browser.searchText = "old query"
    connections.activate(local.id)
    do {
        try await connections.createBox(on: remote.id, harness: "demo-harness", repository: "")
        Issue.record("Creation should fail")
    } catch { }
    #expect(connections.active === local)
    #expect(connections.browser.filter == .archived)
    #expect(connections.browser.searchText == "old query")
    connections.disconnectAll()
}
private let studioProfile = ConnectionProfile(name: "Studio", endpoint: "https://studio.example.invalid")

@MainActor @Test func simultaneousConnectionsPreserveSelectionAndHaveCompositeBoxIdentity() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    await local.selection.selectBox("demo-ui")
    let localExec = local.selection.execID
    let generation = local.connectionState.connectionID
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    await connections.selectBox(.init(connection: remote.id, box: "demo-api"))
    #expect(local.connectionState.isConnected && remote.connectionState.isConnected)
    #expect(local.selection.sandboxID == "demo-ui")
    #expect(remote.selection.sandboxID == "demo-api")
    #expect(local.selection.execID == localExec)
    #expect(local.connectionState.connectionID == generation)
    #expect(localClient.lifetime.closes == 0)
    #expect(remoteClient.lifetime.closes == 0)
    let sameIDs = connections.switcherBoxes.filter { $0.box.id == "demo-ui" }
    #expect(sameIDs.count == 2)
    #expect(Set(sameIDs.map(\.id)).count == 2)
    #expect(sameIDs.filter { $0.matches("Studio") }.count == 1)
    connections.activate(local.id)
    #expect(connections.active === local)
    #expect(local.selection.execID == localExec)
    connections.disconnectAll()
}

@MainActor @Test func disconnectAndFailedConnectionDoNotAffectOtherComputers() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    connections.disconnect(remote.id)
    #expect(!remote.connectionState.isConnected)
    #expect(local.connectionState.isConnected)
    #expect(remoteClient.lifetime.closes == 1)
    #expect(localClient.lifetime.closes == 0)
    connections.activate(local.id)
    let denied = HostFixture(fail: true)
    let failed = try await connections.connect(studioProfile, demo: true) { denied }
    #expect(!failed.connectionState.isConnected)
    #expect(failed.connectionState.connectionError != nil)
    #expect(connections.active === local)
    #expect(localClient.lifetime.closes == 0)
    connections.disconnectAll()
}

@MainActor @Test func commandsAndMutationsAreRoutedToTheSelectedComputer() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    await connections.selectBox(.init(connection: local.id, box: "demo-ui"))
    await connections.active.selection.openShell()
    #expect(await localClient.count(.newShell) == 1)
    #expect(await remoteClient.count(.newShell) == 0)
    await connections.selectBox(.init(connection: remote.id, box: "demo-ui"))
    await connections.active.selection.openShell()
    #expect(await remoteClient.count(.newShell) == 1)
    #expect(await localClient.count(.newShell) == 1)
    let localCount = local.inventory.sandboxes.count
    try await remote.commands.performBoxAction(.archive, boxID: "demo-api", connection: remote.connectionState.connectionID)
    try await remote.commands.performBoxAction(.purge, boxID: "demo-api", connection: remote.connectionState.connectionID)
    #expect(local.inventory.sandboxes.count == localCount)
    #expect(local.inventory.sandboxes.contains { $0.id == "demo-api" })
    connections.disconnectAll()
}

@MainActor @Test func reconnectingAnAlreadyConnectedComputerReusesItsTransport() async throws {
    let connections = Connections(polling: false)
    let client = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { client }
    let generation = local.connectionState.connectionID
    let again = try await connections.connect(.thisComputer, demo: true) { throw DiscoboxError("Must not create another client") }
    #expect(again === local)
    #expect(again.connectionState.connectionID == generation)
    #expect(client.lifetime.closes == 0)
    connections.syncProfiles([.init(name: "Renamed Studio", endpoint: studioProfile.endpoint)])
    #expect(connections.session(studioProfile.id)?.profile.displayName == "Renamed Studio")
    #expect(local.connectionState.isConnected)
    connections.disconnectAll()
}

@MainActor @Test func capturedComputerOwnsCreationAndCredentialAnswersAfterSwitching() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(pending: true), remoteClient = HostFixture(pending: true)
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    await local.approvalStore.refreshApprovals()
    await remote.approvalStore.refreshApprovals()
    let request = try #require(remote.approvalStore.approvals.first)
    #expect(local.approvalStore.approvals.first?.id == request.id)
    let target = remote
    let originalLocalBoxes = local.inventory.sandboxes.count
    connections.activate(local.id)
    try await target.commands.createBox(harness: "demo-harness", repository: "", prompt: "Fixture task")
    #expect(await remoteClient.count(.createBox) == 1)
    #expect(await localClient.count(.createBox) == 0)
    #expect(local.inventory.sandboxes.count == originalLocalBoxes)
    try await target.approvalStore.answer(request, action: "deny", payload: .object([:]))
    #expect(await remoteClient.count(.answer) == 1)
    #expect(await localClient.count(.answer) == 0)
    #expect(local.approvalStore.approvals.count == 1)
    #expect(remote.approvalStore.approvals.isEmpty)
    connections.disconnectAll()
}
