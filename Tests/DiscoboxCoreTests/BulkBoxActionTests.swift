import Foundation
import Testing
@testable import DiscoboxCore

private actor BulkActionFixture: DiscoboxClient {
    let demo = DemoClient()
    var mutations: [String] = []
    var reads = 0
    var failing: String?
    init(failing: String? = nil) { self.failing = failing }
    func reset() { mutations = []; reads = 0 }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .sandboxes { reads += 1 }
        if request.operation == .boxAction {
            mutations.append(request.sandboxID ?? "")
            if request.sandboxID == failing { throw DiscoboxError("Fixture refused this box") }
        }
        return try await demo.perform(request)
    }
}

@MainActor @Test func bulkLifecycleUsesCapturedManifestAndReportsPartialFailures() async throws {
    let client = BulkActionFixture(failing: "demo-tests"), workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    await client.reset()
    var receipts: [String] = []
    let result = try await workspace.performBoxActions(.archive, boxIDs: ["demo-api", "demo-tests", "demo-api"], connection: workspace.connectionID,
        onAccepted: { receipts.append($0) })
    #expect(result.accepted == ["demo-api"] && receipts == ["demo-api"])
    #expect(result.failures.map(\.boxID) == ["demo-tests"])
    #expect(await client.mutations == ["demo-api", "demo-tests"])
    #expect(await client.reads == 1)
    #expect(workspace.sandboxes.first { $0.id == "demo-api" }?.isArchived == true)
    workspace.disconnect()
}

@MainActor @Test func bulkLifecycleRejectsMixedAvailabilityBeforeAnyWrite() async throws {
    let client = BulkActionFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    await client.reset()
    await #expect(throws: DiscoboxError.self) {
        _ = try await workspace.performBoxActions(.stop, boxIDs: ["demo-ui", "demo-api"], connection: workspace.connectionID)
    }
    await #expect(throws: DiscoboxError.self) {
        _ = try await workspace.performBoxActions(.rename, boxIDs: ["demo-ui"], connection: workspace.connectionID)
    }
    #expect(await client.mutations.isEmpty)
    workspace.disconnect()
}

@MainActor @Test func bulkLifecycleSupportsStartStopArchiveRestoreUpgradeAndRepair() async throws {
    let client = BulkActionFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    for action: BoxAction in [.repair, .stop, .archive, .unarchive, .start, .upgrade] {
        await client.reset()
        let result = try await workspace.performBoxActions(action, boxIDs: ["demo-api", "demo-tests"], connection: workspace.connectionID)
        #expect(result.accepted == ["demo-api", "demo-tests"])
        #expect(result.failures.isEmpty)
        #expect(await client.mutations == ["demo-api", "demo-tests"])
        #expect(await client.reads == 1)
    }
    workspace.disconnect()
}

@MainActor @Test func bulkLifecycleStopsAfterReconnectWithoutReportingAnUnconfirmedSuccess() async throws {
    let client = BulkActionFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    await client.reset()
    let generation = workspace.connectionID
    let result = try await workspace.performBoxActions(.archive, boxIDs: ["demo-api", "demo-tests"], connection: generation,
        onAccepted: { _ in workspace.disconnect() })
    #expect(result.accepted == ["demo-api"])
    #expect(result.failures.map(\.boxID) == ["demo-tests"])
    #expect(await client.mutations == ["demo-api"])
}

@MainActor @Test func liveMultiselectionSurvivesPreviewAndScopesIdenticalIDsByComputer() async throws {
    let hub = Connections(polling: false)
    let local = try await hub.connect(.init(name: "Local", endpoint: "unix://"), demo: true) { DemoClient() }
    let remote = try await hub.connect(.init(name: "Remote", endpoint: "https://fixture.test"), demo: true) { DemoClient() }
    let a = BoxLocation(connection: local.id, box: "demo-ui"), b = BoxLocation(connection: local.id, box: "demo-api")
    let c = BoxLocation(connection: remote.id, box: "demo-ui")
    hub.browser.selectBoxes([a, b])
    await hub.selectBox(a)
    #expect(hub.browser.selectedBoxes == [a, b])
    hub.browser.selectBoxes([a, b, c])
    #expect(hub.browser.selectedBoxes == [c])
    hub.browser.toggleComputer(local.id)
    #expect(hub.browser.selectedBoxes.isEmpty)
    hub.disconnectAll()
}
