import Foundation
import Testing
@testable import DiscoboxCore

@MainActor struct HarnessManagementTests {
    @Test func reviewAndSaveRemainOnTheChosenBoxAndPublishDurableReceipt() async throws {
        let client = HarnessFixture()
        let workspace = Workspace()
        await workspace.connect(client: client, label: "fixture", demo: true)
        let model = HarnessManagement(workspace: workspace, harnessID: "demo-harness")
        await model.load()
        model.selectBox("demo-ui")
        await model.refreshPreview()
        #expect(model.canSave)
        await workspace.selectBox("demo-api")
        await model.answer(save: true)
        #expect(model.result["state"].string == "saved-handoff-pending")
        #expect(!model.canSave && model.review == .null)
        let writes = await client.writes
        #expect(writes.count == 1)
        #expect(writes[0].sandboxID == "demo-ui")
        #expect(writes[0].harnessID == "demo-harness")
        #expect(writes[0].payload?["candidateId"] == .string("demo-candidate"))
        #expect(writes[0].payload?["ttlSeconds"] == .null)
        await model.answer(save: true)
        #expect(await client.writes.count == 1)
    }
    @Test func ambiguousSaveRequiresFreshReviewAndReconnectionCannotRetarget() async throws {
        let client = HarnessFixture(failSave: true)
        let workspace = Workspace()
        await workspace.connect(client: client, label: "fixture", demo: true)
        let model = HarnessManagement(workspace: workspace, harnessID: "demo-harness")
        model.selectBox("demo-ui")
        await model.refreshPreview()
        await model.answer(save: true)
        #expect(model.error != nil && model.review == .null && !model.canSave)
        await model.answer(save: true)
        #expect(await client.writes.count == 1)
        await model.refreshPreview()
        workspace.disconnect()
        await workspace.connect(client: DemoClient(), label: "replacement", demo: true)
        await model.answer(save: true)
        #expect(!model.validConnection)
        #expect(await client.writes.count == 1)
    }
    @Test func mismatchedReceiptIsNotShownAsASuccessfulSave() async throws {
        let client = HarnessFixture(wrongReceipt: true)
        let workspace = Workspace()
        await workspace.connect(client: client, label: "fixture", demo: true)
        let model = HarnessManagement(workspace: workspace, harnessID: "demo-harness")
        model.selectBox("demo-ui"); await model.refreshPreview(); await model.answer(save: true)
        #expect(model.result == .null && model.error != nil && model.review == .null)
        #expect(await client.writes.count == 1)
    }
    @Test func legacyReadinessIsDistinctFromARefreshableSavedLogin() throws {
        let current = try JSONDecoder().decode(Harness.self, from: Data(#"{"id":"h","name":"Agent"}"#.utf8))
        let old = try JSONDecoder().decode(Harness.self, from: Data(#"{"id":"h","name":"Agent","configured":false,"configCommand":["setup"]}"#.utf8))
        #expect(current.configured && !current.usesLegacySetup)
        #expect(!old.configured && old.usesLegacySetup)
    }
}

private actor HarnessFixture: DiscoboxClient {
    let base = DemoClient()
    let failSave: Bool
    let wrongReceipt: Bool
    var writes: [BridgeRequest] = []
    init(failSave: Bool = false, wrongReceipt: Bool = false) { self.failSave = failSave; self.wrongReceipt = wrongReceipt }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .saveHarnessChanges {
            writes.append(request)
            if wrongReceipt { return Data(#"{"state":"saved","harnessConfigId":"other","candidateId":"demo-candidate"}"#.utf8) }
            if failSave { throw DiscoboxError("Save may have succeeded. Refresh before retrying.") }
            return Data(#"{"state":"saved-handoff-pending","candidateId":"demo-candidate","harnessConfigId":"demo-harness"}"#.utf8)
        }
        return try await base.perform(request)
    }
}
