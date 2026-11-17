import Foundation
import Testing
@testable import DiscoboxCore

@Test func deletedBoxesAreNotArchivesAndHaveNoLifecycleActions() throws {
    for runtime in [#"{"state":"deleted"}"#, #"{"state":"ready","displayState":"deleted"}"#, #"{"state":"deleted","displayState":"archived"}"#] {
        let box = try JSONDecoder().decode(Sandbox.self, from: Data("{\"id\":\"s\",\"projectId\":\"p\",\"displayName\":\"Deleted\",\"config\":{},\"runtime\":\(runtime)}".utf8))
        #expect(box.isDeleted && !box.isArchived)
        #expect(BoxAction.allCases.allSatisfy { !$0.isAvailable(for: box) })
    }
}

@Test func lifecycleAvailabilityUsesDisplayState() throws {
    let data = Data(#"{"id":"s","projectId":"p","displayName":"Box","harnessConfig":{"name":"Claude Code"},"config":{"source":{"url":"https://github.com/example/project.git"}},"runtime":{"state":"ready","runtimeState":"running","displayState":"archiving","agentStatus":{"sources":[{"slug":"primary","branch":"feature/mac"}]}}}"#.utf8)
    let box = try JSONDecoder().decode(Sandbox.self, from: data)
    #expect(box.status == "Archiving")
    #expect(!box.isRunning)
    #expect(BoxAction.allCases.allSatisfy { !$0.isAvailable(for: box) })
    #expect(box.repository == "example/project")
    #expect(box.harnessName == "Claude Code")
    #expect(box.branch == "feature/mac")
}

@MainActor @Test func boxActionsTargetExplicitBoxAndArchiveRestorePurge() async throws {
    let hub = Connections(polling: false)
    let workspace = hub.active
    await workspace.connect(client: DemoClient(), label: "offline", demo: true)
    await workspace.selection.selectBox("demo-ui")
    let connection = workspace.connectionState.connectionID
    try await workspace.commands.performBoxAction(.start, boxID: "demo-api", connection: connection)
    #expect(workspace.selection.sandboxID == "demo-ui")
    #expect(workspace.inventory.sandboxes.first { $0.id == "demo-api" }?.isRunning == true)
    try await workspace.commands.performBoxAction(.archive, boxID: "demo-api", connection: connection)
    #expect(!hub.browserBoxes.map(\.box).contains { $0.id == "demo-api" })
    hub.browser.filter = .archived
    #expect(hub.browserBoxes.map(\.box).map(\.id) == ["demo-api"])
    try await workspace.commands.performBoxAction(.unarchive, boxID: "demo-api", connection: connection)
    #expect(hub.browserBoxes.map(\.box).isEmpty)
    try await workspace.commands.performBoxAction(.archive, boxID: "demo-api", connection: connection)
    try await workspace.commands.performBoxAction(.purge, boxID: "demo-api", connection: connection)
    #expect(!workspace.inventory.sandboxes.contains { $0.id == "demo-api" })
    #expect(workspace.pending.pendingBoxActions.isEmpty)
}

@MainActor @Test func staleConnectionAndActivePurgeAreRejected() async throws {
    let hub = Connections(polling: false)
    let workspace = hub.active
    await workspace.connect(client: DemoClient(), label: "offline", demo: true)
    let old = workspace.connectionState.connectionID
    await workspace.connect(client: DemoClient(), label: "another", demo: true)
    await #expect(throws: DiscoboxError.self) {
        try await workspace.commands.performBoxAction(.stop, boxID: "demo-ui", connection: old)
    }
    await #expect(throws: DiscoboxError.self) {
        try await workspace.commands.performBoxAction(.purge, boxID: "demo-ui", connection: workspace.connectionState.connectionID)
    }
    #expect(workspace.inventory.sandboxes.first { $0.id == "demo-ui" }?.isRunning == true)
}

@MainActor @Test func disruptiveActionClearsSelectionBeforeSubmission() async throws {
    let hub = Connections(polling: false)
    let workspace = hub.active
    await workspace.connect(client: DemoClient(), label: "offline", demo: true)
    await workspace.selection.selectBox("demo-ui")
    var detached = false
    try await workspace.commands.performBoxAction(.stop, boxID: "demo-ui", connection: workspace.connectionState.connectionID) {
        #expect(workspace.selection.sandboxID == nil)
        #expect(workspace.pending.pendingBoxActions.contains("demo-ui"))
        detached = true
    }
    #expect(detached)
    #expect(workspace.inventory.sandboxes.first { $0.id == "demo-ui" }?.isRunning == false)
}
