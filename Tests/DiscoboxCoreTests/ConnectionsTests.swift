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
}

@MainActor @Test func remoteCreationLeavesArchivedAndSelectsTheDestinationComputer() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    local.workspace.filter = .archived
    remote.workspace.filter = .archived
    remote.workspace.searchText = "old query"
    connections.activate(local.id)
    try await connections.createBox(on: remote.id, harness: "demo-harness", repository: "", prompt: "Fixture task")
    #expect(connections.active === remote)
    #expect(remote.workspace.filter == .all)
    #expect(remote.workspace.searchText.isEmpty)
    #expect(remote.workspace.selectedBox?.displayName == "New demo box")
    #expect(remote.workspace.visibleBoxes.contains { $0.id == remote.workspace.sandboxID })
    #expect(local.workspace.filter == .archived)
    #expect(await remoteClient.count(.createBox) == 1)
    #expect(await localClient.count(.createBox) == 0)
    connections.disconnectAll()
}

@MainActor @Test func failedRemoteCreationPreservesTheCurrentComputerAndFilters() async throws {
    let connections = Connections(polling: false)
    let local = try await connections.connect(.thisComputer, demo: true) { HostFixture() }
    let remote = try await connections.connect(studioProfile, demo: true) { HostFixture(failCreation: true) }
    remote.workspace.filter = .archived
    remote.workspace.searchText = "old query"
    connections.activate(local.id)
    do {
        try await connections.createBox(on: remote.id, harness: "demo-harness", repository: "")
        Issue.record("Creation should fail")
    } catch { }
    #expect(connections.active === local)
    #expect(remote.workspace.filter == .archived)
    #expect(remote.workspace.searchText == "old query")
    connections.disconnectAll()
}
private let studioProfile = ConnectionProfile(name: "Studio", endpoint: "https://studio.example.invalid")

@MainActor @Test func simultaneousConnectionsPreserveSelectionAndHaveCompositeBoxIdentity() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    await local.workspace.selectBox("demo-ui")
    let localExec = local.workspace.execID
    let generation = local.workspace.connectionID
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    await connections.selectBox(.init(connection: remote.id, box: "demo-api"))
    #expect(local.workspace.isConnected && remote.workspace.isConnected)
    #expect(local.workspace.sandboxID == "demo-ui")
    #expect(remote.workspace.sandboxID == "demo-api")
    #expect(local.workspace.execID == localExec)
    #expect(local.workspace.connectionID == generation)
    #expect(localClient.lifetime.closes == 0)
    #expect(remoteClient.lifetime.closes == 0)
    let sameIDs = connections.switcherBoxes.filter { $0.box.id == "demo-ui" }
    #expect(sameIDs.count == 2)
    #expect(Set(sameIDs.map(\.id)).count == 2)
    #expect(sameIDs.filter { $0.matches("Studio") }.count == 1)
    connections.activate(local.id)
    #expect(connections.active === local)
    #expect(local.workspace.execID == localExec)
    connections.disconnectAll()
}

@MainActor @Test func disconnectAndFailedConnectionDoNotAffectOtherComputers() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(), remoteClient = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    connections.disconnect(remote.id)
    #expect(!remote.workspace.isConnected)
    #expect(local.workspace.isConnected)
    #expect(remoteClient.lifetime.closes == 1)
    #expect(localClient.lifetime.closes == 0)
    connections.activate(local.id)
    let denied = HostFixture(fail: true)
    let failed = try await connections.connect(studioProfile, demo: true) { denied }
    #expect(!failed.workspace.isConnected)
    #expect(failed.workspace.connectionError != nil)
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
    await connections.active.workspace.openShell()
    #expect(await localClient.count(.newShell) == 1)
    #expect(await remoteClient.count(.newShell) == 0)
    await connections.selectBox(.init(connection: remote.id, box: "demo-ui"))
    await connections.active.workspace.openShell()
    #expect(await remoteClient.count(.newShell) == 1)
    #expect(await localClient.count(.newShell) == 1)
    let localCount = local.workspace.sandboxes.count
    try await remote.workspace.performBoxAction(.archive, boxID: "demo-api", connection: remote.workspace.connectionID)
    try await remote.workspace.performBoxAction(.purge, boxID: "demo-api", connection: remote.workspace.connectionID)
    #expect(local.workspace.sandboxes.count == localCount)
    #expect(local.workspace.sandboxes.contains { $0.id == "demo-api" })
    connections.disconnectAll()
}

@MainActor @Test func reconnectingAnAlreadyConnectedComputerReusesItsTransport() async throws {
    let connections = Connections(polling: false)
    let client = HostFixture()
    let local = try await connections.connect(.thisComputer, demo: true) { client }
    let generation = local.workspace.connectionID
    let again = try await connections.connect(.thisComputer, demo: true) { throw DiscoboxError("Must not create another client") }
    #expect(again === local)
    #expect(again.workspace.connectionID == generation)
    #expect(client.lifetime.closes == 0)
    connections.syncProfiles([.init(name: "Renamed Studio", endpoint: studioProfile.endpoint)])
    #expect(connections.session(studioProfile.id)?.profile.displayName == "Renamed Studio")
    #expect(local.workspace.isConnected)
    connections.disconnectAll()
}

@MainActor @Test func capturedComputerOwnsCreationAndCredentialAnswersAfterSwitching() async throws {
    let connections = Connections(polling: false)
    let localClient = HostFixture(pending: true), remoteClient = HostFixture(pending: true)
    let local = try await connections.connect(.thisComputer, demo: true) { localClient }
    let remote = try await connections.connect(studioProfile, demo: true) { remoteClient }
    await local.workspace.refreshApprovals()
    await remote.workspace.refreshApprovals()
    let request = try #require(remote.workspace.approvals.first)
    #expect(local.workspace.approvals.first?.id == request.id)
    let target = remote.workspace
    let originalLocalBoxes = local.workspace.sandboxes.count
    connections.activate(local.id)
    try await target.createBox(harness: "demo-harness", repository: "", prompt: "Fixture task")
    #expect(await remoteClient.count(.createBox) == 1)
    #expect(await localClient.count(.createBox) == 0)
    #expect(local.workspace.sandboxes.count == originalLocalBoxes)
    try await target.answer(request, action: "deny", payload: .object([:]))
    #expect(await remoteClient.count(.answer) == 1)
    #expect(await localClient.count(.answer) == 0)
    #expect(local.workspace.approvals.count == 1)
    #expect(remote.workspace.approvals.isEmpty)
    connections.disconnectAll()
}
