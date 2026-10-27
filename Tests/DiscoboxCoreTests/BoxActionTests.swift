import Foundation
import Testing
@testable import DiscoboxCore

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
    let workspace = Workspace()
    await workspace.connect(client: DemoClient(), label: "offline", demo: true)
    await workspace.selectBox("demo-ui")
    let connection = workspace.connectionID
    try await workspace.performBoxAction(.start, boxID: "demo-api", connection: connection)
    #expect(workspace.sandboxID == "demo-ui")
    #expect(workspace.sandboxes.first { $0.id == "demo-api" }?.isRunning == true)
    try await workspace.performBoxAction(.archive, boxID: "demo-api", connection: connection)
    #expect(!workspace.visibleBoxes.contains { $0.id == "demo-api" })
    workspace.filter = .archived
    #expect(workspace.visibleBoxes.map(\.id) == ["demo-api"])
    try await workspace.performBoxAction(.unarchive, boxID: "demo-api", connection: connection)
    #expect(workspace.visibleBoxes.isEmpty)
    try await workspace.performBoxAction(.archive, boxID: "demo-api", connection: connection)
    try await workspace.performBoxAction(.purge, boxID: "demo-api", connection: connection)
    #expect(!workspace.sandboxes.contains { $0.id == "demo-api" })
    #expect(workspace.pendingBoxActions.isEmpty)
}

@MainActor @Test func staleConnectionAndActivePurgeAreRejected() async throws {
    let workspace = Workspace()
    await workspace.connect(client: DemoClient(), label: "offline", demo: true)
    let old = workspace.connectionID
    await workspace.connect(client: DemoClient(), label: "another", demo: true)
    await #expect(throws: DiscoboxError.self) {
        try await workspace.performBoxAction(.stop, boxID: "demo-ui", connection: old)
    }
    await #expect(throws: DiscoboxError.self) {
        try await workspace.performBoxAction(.purge, boxID: "demo-ui", connection: workspace.connectionID)
    }
    #expect(workspace.sandboxes.first { $0.id == "demo-ui" }?.isRunning == true)
}

@MainActor @Test func disruptiveActionClearsSelectionBeforeSubmission() async throws {
    let workspace = Workspace()
    await workspace.connect(client: DemoClient(), label: "offline", demo: true)
    await workspace.selectBox("demo-ui")
    var detached = false
    try await workspace.performBoxAction(.stop, boxID: "demo-ui", connection: workspace.connectionID) {
        #expect(workspace.sandboxID == nil)
        #expect(workspace.pendingBoxActions.contains("demo-ui"))
        detached = true
    }
    #expect(detached)
    #expect(workspace.sandboxes.first { $0.id == "demo-ui" }?.isRunning == false)
}
