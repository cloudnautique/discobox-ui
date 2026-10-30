import Foundation
import Testing
@testable import DiscoboxCore

@MainActor private func browsingComputers() async throws -> (Connections, ConnectionSession, ConnectionSession) {
    let hub = Connections(polling: false)
    let local = try await hub.connect(.thisComputer, demo: true) { DemoClient() }
    let remote = try await hub.connect(.init(name: "Studio computer", endpoint: "https://studio.example.invalid"), demo: true) { DemoClient() }
    return (hub, local, remote)
}

@MainActor @Test func noComputerFilterIncludesEveryConnectedHostWithCompositeIdentity() async throws {
    let (hub, local, remote) = try await browsingComputers()
    #expect(hub.browser.computerID == nil)
    #expect(hub.browserBoxes.count == local.workspace.sandboxes.count + remote.workspace.sandboxes.count)
    #expect(Set(hub.browserBoxes.map(\.location)).count == hub.browserBoxes.count)
    #expect(hub.browserBoxes.filter { $0.box.id == "demo-ui" }.count == 2)
    hub.disconnect(remote.id)
    #expect(hub.browserBoxes.allSatisfy { $0.location.connection == local.id })
    hub.disconnectAll()
}

@MainActor @Test func togglingComputerOnlyFiltersTheListAndTogglingAgainShowsAll() async throws {
    let (hub, local, remote) = try await browsingComputers()
    await hub.selectBox(.init(connection: local.id, box: "demo-ui"))
    let generation = local.workspace.connectionID
    hub.browser.toggleComputer(remote.id)
    #expect(hub.browserBoxes.count == remote.workspace.sandboxes.count)
    #expect(hub.browserBoxes.allSatisfy { $0.location.connection == remote.id })
    #expect(hub.active === local && local.workspace.sandboxID == "demo-ui")
    hub.browser.toggleComputer(remote.id)
    #expect(hub.browser.computerID == nil && hub.browserBoxes.count == 6)
    #expect(local.workspace.connectionID == generation)
    hub.disconnectAll()
}

@MainActor @Test func newBoxDefaultsToTheFilteredComputerOrAnAvailableActiveHost() async throws {
    let (hub, local, remote) = try await browsingComputers()
    hub.activate(local.id)
    #expect(hub.suggestedCreationComputerID == local.id)
    hub.browser.toggleComputer(remote.id)
    #expect(hub.suggestedCreationComputerID == remote.id)
    hub.browser.toggleComputer(remote.id)
    #expect(hub.suggestedCreationComputerID == local.id)
    hub.disconnect(local.id)
    #expect(hub.suggestedCreationComputerID == remote.id)
    hub.disconnectAll()
}

@MainActor @Test func openingABoxPreservesTheAllComputersFilterAndSearchChoices() async throws {
    let (hub, _, remote) = try await browsingComputers()
    hub.browser.searchText = "demo"
    hub.browser.selectedTags = ["repository"]
    hub.browser.matchAnyTag = true
    await hub.selectBox(.init(connection: remote.id, box: "demo-ui"))
    #expect(hub.active === remote)
    #expect(hub.browser.computerID == nil)
    #expect(hub.browser.searchText == "demo")
    #expect(hub.browser.selectedTags == ["repository"] && hub.browser.matchAnyTag)
    hub.disconnectAll()
}

@MainActor @Test func browsingFiltersAndGroupingOperateAcrossHosts() async throws {
    let (hub, local, remote) = try await browsingComputers()
    hub.browser.searchText = "Studio computer Claude"
    #expect(hub.browserBoxes.count == 1)
    #expect(hub.browserBoxes.first?.location.connection == remote.id)
    hub.browser.searchText = ""
    hub.browser.filter = .running
    #expect(hub.browserBoxes.count == 2)
    hub.browser.selectedTags = ["repository=discobox-ui", "branch=missing"]
    #expect(hub.browserBoxes.isEmpty)
    hub.browser.matchAnyTag = true
    #expect(hub.browserBoxes.count == 2)
    let groups = Dictionary(grouping: hub.browserBoxes) { BoxOrganization.group($0.box, by: "repository", tagKey: "") }
    #expect(groups["discobox-ui"]?.count == 2)
    #expect(Set(groups["discobox-ui"]!.map { $0.location.connection }) == [local.id, remote.id])
    hub.disconnectAll()
}

@MainActor @Test func combinedArchivesKeepBulkPurgeScopedToOneHost() async throws {
    let (hub, local, remote) = try await browsingComputers()
    for host in [local, remote] {
        try await host.workspace.performBoxAction(.archive, boxID: "demo-api", connection: host.workspace.connectionID)
    }
    hub.browser.filter = .archived
    let a = BoxLocation(connection: local.id, box: "demo-api"), b = BoxLocation(connection: remote.id, box: "demo-api")
    #expect(Set(hub.browserBoxes.map(\.location)) == [a, b])
    hub.browser.selectArchives([a])
    hub.browser.selectArchives([a, b])
    #expect(hub.browser.archivedSelection == [b])
    hub.browser.toggleComputer(local.id)
    #expect(hub.browser.archivedSelection.isEmpty)
    #expect(hub.browserBoxes.map(\.location) == [a])
    await hub.selectBox(a)
    #expect(hub.browser.archivedSelection == [a])
    await hub.selectBox(.init(connection: local.id, box: "demo-ui"))
    #expect(hub.browser.filter == .all && hub.browser.archivedSelection.isEmpty)
    hub.disconnectAll()
}

@MainActor @Test func creationKeepsAllComputersVisibleAndClearsFiltersThatHideTheNewBox() async throws {
    let (hub, _, remote) = try await browsingComputers()
    hub.browser.filter = .archived
    hub.browser.searchText = "old work"
    hub.browser.selectedTags = ["branch=old"]
    try await hub.createBox(on: remote.id, harness: "demo-harness", repository: "")
    #expect(hub.browser.computerID == nil)
    #expect(hub.browser.filter == .all && hub.browser.searchText.isEmpty && hub.browser.selectedTags.isEmpty)
    #expect(hub.browserBoxes.contains { $0.location.connection == remote.id && $0.box.id == remote.workspace.sandboxID })
    hub.disconnectAll()
}
