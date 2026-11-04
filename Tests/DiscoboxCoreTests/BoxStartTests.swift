import Foundation
import Testing
@testable import DiscoboxCore

private actor StartFixture: DiscoboxClient {
    let demo = DemoClient()
    let fail: Bool
    private(set) var starts: [String] = []
    init(fail: Bool = false) { self.fail = fail }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .boxAction && request.action == "start" {
            starts.append(request.sandboxID ?? "")
            if fail { throw DiscoboxError("Fixture: host cannot start this box") }
        }
        return try await demo.perform(request)
    }
}

@MainActor @Test func stoppedBoxPromptIsPassiveAndStartPreservesBrowsingContext() async throws {
    let client = StartFixture()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "Fixture computer", demo: true)
    await workspace.selectBox("demo-api")
    workspace.filter = .running
    workspace.searchText = "keep this search"
    let box = try #require(workspace.selectedBox)
    let intent = BoxStartIntent(workspace: workspace, box: box, computer: "Fixture computer")
    #expect(intent.canStart && !intent.alreadyRunning)
    #expect(await client.starts.isEmpty)
    #expect(!workspace.visibleBoxes.contains { $0.id == box.id })
    // Switching selection while the decision is open must never retarget Start.
    await workspace.selectBox("demo-ui")
    #expect(await intent.start())
    #expect(await client.starts == ["demo-api"])
    #expect(workspace.sandboxes.first { $0.id == "demo-api" }?.isRunning == true)
    #expect(workspace.sandboxID == "demo-ui")
    #expect(workspace.filter == .running && workspace.searchText == "keep this search")
    // Reopening the now-running box gets live execs, not its stale saved state.
    await workspace.selectBox("demo-api")
    #expect(workspace.hasLiveTerminal)
    #expect(workspace.filter == .running && workspace.searchText == "keep this search")
}

@MainActor @Test func stoppedBoxStartKeepsItsComputerDespiteIdenticalIDs() async throws {
    let hub = Connections(polling: false)
    let a = StartFixture(), b = StartFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { a }
    let remote = try await hub.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { b }
    let box = try #require(remote.workspace.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(workspace: remote.workspace, box: box, computer: remote.profile.displayName)
    hub.browser.filter = .running
    hub.browser.computerID = local.id
    hub.activate(local.id)
    #expect(await intent.start())
    #expect(await a.starts.isEmpty)
    #expect(await b.starts == [box.id])
    #expect(local.workspace.sandboxes.first { $0.id == box.id }?.isRunning == false)
    #expect(hub.activeID == local.id && hub.browser.computerID == local.id && hub.browser.filter == .running)
}

@MainActor @Test func stoppedBoxStartRejectsAReconnectedComputer() async throws {
    let old = StartFixture(), replacement = StartFixture()
    let workspace = Workspace()
    await workspace.connect(client: old, label: "Original", demo: true)
    let box = try #require(workspace.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(workspace: workspace, box: box, computer: "Original")
    await workspace.connect(client: replacement, label: "Reconnected", demo: true)
    #expect(!intent.isCurrent && !intent.canStart)
    #expect(await intent.start() == false)
    #expect(intent.failure != nil)
    #expect(await old.starts.isEmpty)
    #expect(await replacement.starts.isEmpty)
}

@MainActor @Test func stoppedBoxStartDoesNotRestartAlreadyRunningOrArchivedBoxes() async throws {
    let client = StartFixture()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "Fixture", demo: true)
    let box = try #require(workspace.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(workspace: workspace, box: box, computer: "Fixture")
    try await workspace.performBoxAction(.start, boxID: box.id, connection: workspace.connectionID)
    #expect(intent.alreadyRunning)
    #expect(await intent.start())
    #expect(await client.starts == [box.id])
    try await workspace.performBoxAction(.archive, boxID: box.id, connection: workspace.connectionID)
    #expect(!intent.canStart && !intent.isCurrent)
    #expect(await intent.start() == false)
    #expect(await client.starts == [box.id])
}

@MainActor @Test func failedStartStaysVisibleWithoutAutomaticRetry() async throws {
    let client = StartFixture(fail: true)
    let workspace = Workspace()
    await workspace.connect(client: client, label: "Fixture", demo: true)
    let box = try #require(workspace.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(workspace: workspace, box: box, computer: "Fixture")
    #expect(await intent.start() == false)
    #expect(intent.failure == "Fixture: host cannot start this box")
    #expect(!intent.working && intent.canStart)
    #expect(await client.starts == [box.id])
    #expect(workspace.pendingBoxActions.isEmpty)
    #expect(workspace.sandboxes.first { $0.id == box.id }?.isRunning == false)
}
