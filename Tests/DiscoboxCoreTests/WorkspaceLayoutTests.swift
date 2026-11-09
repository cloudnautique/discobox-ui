import Testing
import Foundation
@testable import DiscoboxCore

@MainActor @Test func shellVisibilityPreservesSelectionAndSplit() {
    let layout = WorkspaceLayout()
    layout.reconcile(["exec:one", "exec:two"])
    layout.open("exec:one")
    layout.split(with: "exec:two")
    #expect(layout.visibleCompanions == ["exec:one", "exec:two"])
    layout.hideCompanions()
    #expect(layout.selected == "agent")
    #expect(layout.visibleCompanions.isEmpty)
    #expect(layout.lastCompanion == "exec:two")
    #expect(layout.restoreCompanions())
    #expect(layout.selected == "exec:two")
    #expect(layout.shellsSplit)
    layout.mergeShells()
    #expect(layout.visibleCompanions == ["exec:two"])
}

@MainActor @Test func toolNavigationDoesNotDiscardShellLayout() {
    let layout = WorkspaceLayout()
    layout.reconcile(["exec:one", "exec:two"])
    layout.open("exec:one"); layout.split(with: "exec:two")
    layout.open("files")
    #expect(layout.visibleCompanions == ["files"])
    layout.open("exec:one")
    #expect(layout.shellsSplit)
    layout.open("files"); layout.close("files")
    #expect(!layout.tools.contains("files"))
    #expect(layout.isSplit)
}

@MainActor @Test func closingSplitShellSelectsSurvivorAndRepairsRestoreTarget() {
    let layout = WorkspaceLayout()
    layout.reconcile(["exec:one", "exec:two"])
    layout.open("audit"); layout.open("files")
    layout.open("exec:one"); layout.split(with: "exec:two")
    layout.rename("exec:two", to: "Tests")
    layout.reconcile(["exec:one"])
    #expect(layout.selected == "exec:one")
    #expect(!layout.shellsSplit)
    #expect(layout.names.isEmpty)
    layout.hideCompanions(); layout.reconcile([])
    #expect(layout.selected == "agent")
    layout.close("audit"); layout.close("files")
    #expect(!layout.restoreCompanions())
}

@MainActor @Test func paneNavigationVisitsAgentAndBothShells() {
    let layout = WorkspaceLayout()
    layout.reconcile(["exec:one", "exec:two"])
    layout.open("exec:one"); layout.split(with: "exec:two")
    layout.agentFocused = true
    layout.movePane()
    #expect(layout.selected == "exec:one" && !layout.agentFocused)
    layout.movePane()
    #expect(layout.selected == "exec:two")
    layout.movePane()
    #expect(layout.agentFocused)
    layout.movePane(-1)
    #expect(layout.selected == "exec:two" && !layout.agentFocused)
    layout.moveTab(1)
    #expect(layout.selected == "exec:one")
}

@MainActor @Test func layoutsAreIndependentAcrossComputersAndBoxes() {
    let first = WorkspaceLayout(), second = WorkspaceLayout()
    first.reconcile(["exec:one"]); second.reconcile(["exec:one"])
    first.open("exec:one"); first.rename("exec:one", to: "Build")
    #expect(second.selected == "agent")
    #expect(second.names.isEmpty)
    second.open("exec:one"); first.hideCompanions()
    #expect(second.isSplit)
}

private func repositoryFixture(_ source: JSONValue, created: String = "") throws -> Sandbox {
    let data = try JSONEncoder().encode(JSONValue.object([
        "id": .string(UUID().uuidString), "projectId": .string("fixture"), "displayName": .string("Fixture"),
        "createdAt": .string(created), "config": .object(["source": source]), "runtime": .object(["state": .string("ready")])
    ]))
    return try JSONDecoder().decode(Sandbox.self, from: data)
}

@Test func repositorySuggestionsKeepCloneURLAndExcludeMachinePathsAndCredentials() throws {
    let ssh = try repositoryFixture(.object(["url": .string("git@github.com:acme/private.git")]))
    #expect(RepositoryChoice(box: ssh)?.source == "git@github.com:acme/private.git")
    #expect(RepositoryChoice(box: ssh)?.title == "acme/private")
    for value in ["https://token@github.com/acme/private", "https://user:password@github.com/acme/private", "/Users/example/project", "file:///Users/example/project", "https://github.com/acme/repo?token=secret"] {
        #expect(RepositoryChoice(box: try repositoryFixture(.object(["url": .string(value)]))) == nil)
    }
    #expect(RepositoryChoice(box: try repositoryFixture(.object(["localDirectory": .string("/workspace/source")]))) == nil)
}

@Test func repositorySuggestionsAreRecentDeduplicatedAndBounded() throws {
    let old = try repositoryFixture(.object(["url": .string("https://github.com/acme/api.git")]), created: "2026-01-01")
    let recent = try repositoryFixture(.object(["url": .string("https://github.com/acme/web.git")]), created: "2026-06-01")
    let repeated = try repositoryFixture(.object(["url": .string("https://github.com/acme/api.git")]), created: "2026-05-01")
    #expect(RepositoryChoice.recent(in: [old, recent, repeated]).map(\.title) == ["acme/web", "acme/api"])
    #expect(RepositoryChoice.recent(in: [old, recent], limit: 1).map(\.title) == ["acme/web"])
}

@Test func initialTerminalSharesStayReadableAndRepairOldRatios() {
    #expect(WorkspaceSizing.fraction(preferred: 0.85, length: 687) == 0.5)
    #expect(WorkspaceSizing.fraction(preferred: 0.55, length: 908) == 0.55)
    let share = WorkspaceSizing.fraction(preferred: 0.85, length: 1200)
    #expect(share == 0.7)
    #expect(1200 * (1 - share) >= 360)
    #expect(WorkspaceSizing.fraction(preferred: .nan, length: 1000) == 0.55)
    #expect(WorkspaceSizing.fraction(preferred: 0.8, length: 0) == 0.5)
    #expect(WorkspaceSizing.fraction(preferred: 0.55, length: 1200, secondaryMinimum: 720) == 0.4)
}
