import Foundation
import Testing
@testable import DiscoboxCore

@Test func approvalPolicyRoundTripsResolvedVariablesAndUnknownFields() throws {
    let policy = Data(#"{"statements":[{"effect":"allow"}],"resolved":{"primary.repo":"org/repo"},"future":{"a":true}}"#.utf8)
    let value = try JSONDecoder().decode(JSONValue.self, from: policy)
    let request = BridgeRequest(.answer, projectID: "p", requestID: "r", kind: "credential", action: "approve", payload: .object(["policy": value, "grantTTLSeconds": .number(900)]))
    let encoded = try JSONEncoder().encode(request)
    let body = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(body["payload"]["policy"] == value)
}

@MainActor @Test func approvalsRefreshWithoutBoxSelectionAndClearOnDisconnect() async throws {
    let workspace = Workspace()
    let client = InboxFixture()
    await workspace.connect(client: client, label: "fixture")
    #expect(workspace.sandboxID == nil)
    await workspace.refreshApprovals()
    let item = try #require(workspace.approvals.first)
    #expect(item.boxID == "demo-ui")
    try await workspace.answer(item, action: "deny", payload: .object([:]))
    #expect(workspace.approvals.isEmpty)
    #expect(await client.answers == 1)
    workspace.disconnect()
    #expect(workspace.approvals.isEmpty)
}
private actor InboxFixture: DiscoboxClient {
    let demo = DemoClient()
    var answers = 0
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .answer { answers += 1; return Data("{}".utf8) }
        if request.operation == .approvals {
            return Data((answers == 0 ? #"{"approvalRequests":[{"kind":"credential","credential":{"id":"r","sandboxId":"demo-ui","status":"pending","name":"GitHub"}}]}"# : #"{"approvalRequests":[]}"#).utf8)
        }
        return try await demo.perform(request)
    }
}

@Test func demoApprovalFixtureDecodes() async throws {
    let client = DemoClient(pendingRequests: true)
    let inbox = try await client.decode(.init(.approvals), as: ApprovalInbox.self)
    #expect(inbox.approvalRequests.count == 1)
    #expect(inbox.approvalRequests[0].request["policy"]["resolved"]["primary.repo"].string == "example/project")
}

@Test func allInboxKindsRetainTheirIdentityAndUnknownKindsStayVisible() throws {
    for kind in ["credential", "trust", "refresh", "adoption", "apiAccess", "future"] {
        let value: JSONValue = .object(["kind": .string(kind), kind: .object(["id": .string("r-" + kind), "requesterSandboxId": .string("requester"), "status": .string("pending"), "futurePolicy": .bool(true)])])
        let item = try JSONDecoder().decode(ApprovalItem.self, from: JSONEncoder().encode(value))
        #expect(item.id == "r-" + kind)
        #expect(item.boxID == "requester")
        #expect(item.request["futurePolicy"] == .bool(true))
        #expect(item.supported == (kind != "future"))
        if kind != "credential" { #expect(item.notificationApprovalPayload == nil) }
    }
}
