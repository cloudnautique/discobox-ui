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
    let hub = Connections(polling: false)
    let workspace = hub.active
    await workspace.connect(client: client, label: "Fixture computer", demo: true)
    await workspace.selection.selectBox("demo-api")
    hub.browser.filter = .running
    hub.browser.searchText = "keep this search"
    let box = try #require(workspace.selection.selectedBox)
    let intent = BoxStartIntent(connection: workspace.connectionState, inventory: workspace.inventory, pending: workspace.pending, commands: workspace.commands, box: box, computer: "Fixture computer")
    #expect(intent.canStart && !intent.alreadyRunning)
    #expect(await client.starts.isEmpty)
    #expect(!hub.browserBoxes.map(\.box).contains { $0.id == box.id })
    // Switching selection while the decision is open must never retarget Start.
    await workspace.selection.selectBox("demo-ui")
    #expect(await intent.start())
    #expect(await client.starts == ["demo-api"])
    #expect(workspace.inventory.sandboxes.first { $0.id == "demo-api" }?.isRunning == true)
    #expect(workspace.selection.sandboxID == "demo-ui")
    #expect(hub.browser.filter == .running && hub.browser.searchText == "keep this search")
    // Reopening the now-running box gets live execs, not its stale saved state.
    await workspace.selection.selectBox("demo-api")
    #expect(workspace.selection.hasLiveTerminal)
    #expect(hub.browser.filter == .running && hub.browser.searchText == "keep this search")
}

@MainActor @Test func stoppedBoxStartKeepsItsComputerDespiteIdenticalIDs() async throws {
    let hub = Connections(polling: false)
    let a = StartFixture(), b = StartFixture()
    let local = try await hub.connect(.thisComputer, demo: true) { a }
    let remote = try await hub.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { b }
    let box = try #require(remote.inventory.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(connection: remote.connectionState, inventory: remote.inventory, pending: remote.pending, commands: remote.commands, box: box, computer: remote.profile.displayName)
    hub.browser.filter = .running
    hub.browser.computerID = local.id
    hub.activate(local.id)
    #expect(await intent.start())
    #expect(await a.starts.isEmpty)
    #expect(await b.starts == [box.id])
    #expect(local.inventory.sandboxes.first { $0.id == box.id }?.isRunning == false)
    #expect(hub.activeID == local.id && hub.browser.computerID == local.id && hub.browser.filter == .running)
}

@MainActor @Test func stoppedBoxStartRejectsAReconnectedComputer() async throws {
    let old = StartFixture(), replacement = StartFixture()
    let hub = Connections(polling: false)
    let workspace = hub.active
    await workspace.connect(client: old, label: "Original", demo: true)
    let box = try #require(workspace.inventory.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(connection: workspace.connectionState, inventory: workspace.inventory, pending: workspace.pending, commands: workspace.commands, box: box, computer: "Original")
    await workspace.connect(client: replacement, label: "Reconnected", demo: true)
    #expect(!intent.isCurrent && !intent.canStart)
    #expect(await intent.start() == false)
    #expect(intent.failure != nil)
    #expect(await old.starts.isEmpty)
    #expect(await replacement.starts.isEmpty)
}

@MainActor @Test func stoppedBoxStartDoesNotRestartAlreadyRunningOrArchivedBoxes() async throws {
    let client = StartFixture()
    let hub = Connections(polling: false)
    let workspace = hub.active
    await workspace.connect(client: client, label: "Fixture", demo: true)
    let box = try #require(workspace.inventory.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(connection: workspace.connectionState, inventory: workspace.inventory, pending: workspace.pending, commands: workspace.commands, box: box, computer: "Fixture")
    try await workspace.commands.performBoxAction(.start, boxID: box.id, connection: workspace.connectionState.connectionID)
    #expect(intent.alreadyRunning)
    #expect(await intent.start())
    #expect(await client.starts == [box.id])
    try await workspace.commands.performBoxAction(.archive, boxID: box.id, connection: workspace.connectionState.connectionID)
    #expect(!intent.canStart && !intent.isCurrent)
    #expect(await intent.start() == false)
    #expect(await client.starts == [box.id])
}

@MainActor @Test func failedStartStaysVisibleWithoutAutomaticRetry() async throws {
    let client = StartFixture(fail: true)
    let hub = Connections(polling: false)
    let workspace = hub.active
    await workspace.connect(client: client, label: "Fixture", demo: true)
    let box = try #require(workspace.inventory.sandboxes.first { $0.id == "demo-api" })
    let intent = BoxStartIntent(connection: workspace.connectionState, inventory: workspace.inventory, pending: workspace.pending, commands: workspace.commands, box: box, computer: "Fixture")
    #expect(await intent.start() == false)
    #expect(intent.failure == "Fixture: host cannot start this box")
    #expect(!intent.working && intent.canStart)
    #expect(await client.starts == [box.id])
    #expect(workspace.pending.pendingBoxActions.isEmpty)
    #expect(workspace.inventory.sandboxes.first { $0.id == box.id }?.isRunning == false)
}
