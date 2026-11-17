import Foundation
import Testing
@testable import DiscoboxCore

@Test func defaultHarnessSelectionRespectsExplicitChoiceAndReadiness() throws {
    let catalog = try JSONDecoder().decode(HarnessList.self, from: Data(#"{"harnessConfigs":[{"id":"first","name":"First","configured":true},{"id":"preferred","name":"Preferred"},{"id":"unready","name":"Unready","configured":false}]}"#.utf8)).harnessConfigs ?? []
    #expect(HarnessSelection.preferred(in: catalog, defaultID: "preferred") == "preferred")
    #expect(HarnessSelection.preferred(in: catalog, defaultID: "preferred", explicitID: "first") == "first")
    #expect(HarnessSelection.preferred(in: catalog, defaultID: "unready") == "first")
    #expect(HarnessSelection.preferred(in: catalog, defaultID: "deleted") == "first")
    #expect(HarnessSelection.preferred(in: [], defaultID: "preferred").isEmpty)
}

@MainActor @Test func defaultHarnessIsSharedProjectMetadataAndClearedOnDisconnect() async throws {
    let client = DefaultHarnessFixture()
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "fixture")
    _ = try await workspace.catalog.harnesses()
    #expect(workspace.catalog.defaultHarnessID == "demo-harness")
    try await workspace.catalog.setDefaultHarness("other", connection: workspace.connectionState.connectionID)
    #expect(workspace.catalog.defaultHarnessID == "other")
    try await workspace.catalog.refreshDefaultHarness()
    #expect(workspace.catalog.defaultHarnessID == "other")
    #expect(await client.writes == 1)
    workspace.disconnect()
    #expect(workspace.catalog.defaultHarnessID == nil)
}

@MainActor @Test func lateDefaultHarnessResponseCannotChangeAnotherComputer() async throws {
    let client = DefaultHarnessFixture(blockWrites: true)
    let workspace = ConnectionSession()
    await workspace.connect(client: client, label: "first")
    _ = try await workspace.catalog.harnesses()
    let generation = workspace.connectionState.connectionID
    let save = Task { try await workspace.catalog.setDefaultHarness("other", connection: generation) }
    await client.waitUntilBlocked()
    await workspace.connect(client: DemoClient(), label: "second")
    await client.release()
    do { try await save.value; Issue.record("A stale write must not update the current computer") }
    catch is CancellationError { }
    #expect(workspace.catalog.defaultHarnessID == nil)
    workspace.disconnect()
}

private actor DefaultHarnessFixture: DiscoboxClient {
    let demo = DemoClient()
    var selected = "demo-harness"
    var writes = 0
    let blockWrites: Bool
    private var blocked: CheckedContinuation<Void, Never>?
    init(blockWrites: Bool = false) { self.blockWrites = blockWrites }
    func waitUntilBlocked() async { while blocked == nil { await Task.yield() } }
    func release() { blocked?.resume(); blocked = nil }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .harnesses {
            return Data(#"{"harnessConfigs":[{"id":"demo-harness","name":"Demo"},{"id":"other","name":"Other"}]}"#.utf8)
        }
        if request.operation == .setDefaultHarness {
            writes += 1
            #expect(request.projectID == "demo")
            selected = request.harnessID ?? ""
            if blockWrites { await withCheckedContinuation { blocked = $0 } }
        }
        if request.operation == .defaultProject || request.operation == .setDefaultHarness {
            return try JSONSerialization.data(withJSONObject: ["id": "demo", "name": "Demo", "defaultHarnessConfigId": selected])
        }
        return try await demo.perform(request)
    }
}
