import Foundation
import Testing
@testable import DiscoboxCore

private actor BulkPurgeFixture: DiscoboxClient {
    let demo = DemoClient()
    let failingBox: String?
    var purges: [String] = []
    var inventoryReads = 0
    var staleInventory: Data?
    init(failingBox: String? = nil) { self.failingBox = failingBox }
    func resetCounts() { purges = []; inventoryReads = 0 }
    func holdInventory() async throws { staleInventory = try await demo.perform(.init(.sandboxes)) }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .sandboxes {
            inventoryReads += 1
            if let staleInventory { return staleInventory }
        }
        if request.operation == .boxAction, request.action == "purge" {
            purges.append(request.sandboxID ?? "")
            if request.sandboxID == failingBox { throw DiscoboxError("Only archived boxes can be purged; fixture box was restored.") }
        }
        return try await demo.perform(request)
    }
}

@MainActor private func archivedWorkspace(_ client: BulkPurgeFixture) async throws -> Workspace {
    let workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    for id in ["demo-api", "demo-tests"] {
        try await workspace.performBoxAction(.archive, boxID: id, connection: workspace.connectionID)
    }
    await client.resetCounts()
    return workspace
}

@MainActor @Test func bulkPurgeDeletesOnlyConfirmedArchivesAndRefreshesOnce() async throws {
    let client = BulkPurgeFixture()
    let workspace = try await archivedWorkspace(client)
    var progress: [Int] = []
    let result = try await workspace.purgeArchivedBoxes(["demo-api", "demo-tests", "demo-api"], connection: workspace.connectionID) { done, total in
        progress.append(done)
        #expect(total == 2)
    }
    #expect(result.purged == ["demo-api", "demo-tests"])
    #expect(result.failures.isEmpty)
    #expect(await client.purges == ["demo-api", "demo-tests"])
    #expect(await client.inventoryReads == 1)
    #expect(progress == [1, 2])
    #expect(workspace.sandboxes.map(\.id) == ["demo-ui"])
    #expect(workspace.sandboxes.first?.isRunning == true)
}

@MainActor @Test func bulkPurgeRejectsMixedAndStaleManifestsBeforeAnyMutation() async throws {
    let client = BulkPurgeFixture()
    let workspace = try await archivedWorkspace(client)
    let connection = workspace.connectionID
    for ids in [["demo-api", "demo-ui"], ["missing"], []] {
        await #expect(throws: DiscoboxError.self) { try await workspace.purgeArchivedBoxes(ids, connection: connection) }
    }
    workspace.disconnect()
    await #expect(throws: DiscoboxError.self) { try await workspace.purgeArchivedBoxes(["demo-api"], connection: connection) }
    #expect(await client.purges.isEmpty)
}

@MainActor @Test func bulkPurgeReportsPartialFailuresWithoutRetrying() async throws {
    let client = BulkPurgeFixture(failingBox: "demo-api")
    let workspace = try await archivedWorkspace(client)
    let result = try await workspace.purgeArchivedBoxes(["demo-api", "demo-tests"], connection: workspace.connectionID)
    #expect(result.purged == ["demo-tests"])
    #expect(result.failures.map(\.boxID) == ["demo-api"])
    #expect(await client.purges == ["demo-api", "demo-tests"])
    #expect(workspace.sandboxes.contains { $0.id == "demo-api" })
    #expect(workspace.pendingBoxActions.isEmpty)
}

@MainActor @Test func bulkPurgeStopsWhenTheConnectionChanges() async throws {
    let client = BulkPurgeFixture()
    let workspace = try await archivedWorkspace(client)
    let result = try await workspace.purgeArchivedBoxes(["demo-api", "demo-tests"], connection: workspace.connectionID) { done, _ in
        if done == 1 { workspace.disconnect() }
    }
    #expect(result.purged == ["demo-api"])
    #expect(result.failures.map(\.boxID) == ["demo-tests"])
    #expect(result.failures.first?.message.hasPrefix("Not attempted") == true)
    #expect(await client.purges == ["demo-api"])
}

@MainActor @Test func everyConfirmedPurgeLeavesImmediatelyAndStaleListsCannotResurrectIt() async throws {
    let client = BulkPurgeFixture(), workspace = try await archivedWorkspace(client)
    try await client.holdInventory()
    let ids = ["demo-api", "demo-tests"]
    let result = try await workspace.purgeArchivedBoxes(ids, connection: workspace.connectionID) { done, _ in
        #expect(!workspace.sandboxes.contains { ids.prefix(done).contains($0.id) })
    }
    #expect(result.purged == ids && result.failures.isEmpty)
    #expect(await client.purges == ids)
    await workspace.refresh()
    #expect(workspace.sandboxes.map(\.id) == ["demo-ui"])
    await workspace.selectBox("demo-api")
    #expect(workspace.sandboxID == nil)
    // The same IDs on a new connection are unrelated to the previous receipts.
    await workspace.connect(client: DemoClient(), label: "New computer", demo: true)
    #expect(workspace.sandboxes.contains { $0.id == "demo-api" })
}

@MainActor @Test func failedPurgeRemainsVisibleWhenOtherConfirmedPurgesDisappear() async throws {
    let client = BulkPurgeFixture(failingBox: "demo-api"), workspace = try await archivedWorkspace(client)
    try await client.holdInventory()
    let result = try await workspace.purgeArchivedBoxes(["demo-api", "demo-tests"], connection: workspace.connectionID)
    #expect(result.purged == ["demo-tests"])
    await workspace.refresh()
    #expect(workspace.sandboxes.contains { $0.id == "demo-api" })
    #expect(!workspace.sandboxes.contains { $0.id == "demo-tests" })
}

@MainActor @Test func openingSelectedArchiveDoesNotCollapseMultiSelection() async throws {
    let connections = Connections(polling: false)
    let host = try await connections.connect(.thisComputer, demo: true) { DemoClient() }
    for id in ["demo-api", "demo-tests"] {
        try await host.workspace.performBoxAction(.archive, boxID: id, connection: host.workspace.connectionID)
    }
    connections.browser.filter = .archived
    let selection: Set<BoxLocation> = Set(["demo-api", "demo-tests"].map { .init(connection: host.id, box: $0) })
    connections.browser.selectArchives(selection)
    await connections.selectBox(.init(connection: host.id, box: "demo-api"))
    #expect(connections.browser.archivedSelection == selection)
    connections.disconnectAll()
}
