import SwiftUI
import DiscoboxCore

@MainActor enum UpstreamIntegrationSmoke {
    static func panels() async throws -> [(String, AnyView)] {
        let workspace = Workspace()
        await workspace.connect(client: UpstreamApprovalFixture(), label: "Integration fixture", demo: true)
        await workspace.refreshApprovals()
        var panels: [(String, AnyView)] = workspace.approvals.map { item in
            ("upstream-" + item.kind, AnyView(ApprovalSheet(item: item).environment(workspace)))
        }
        panels.append(("pool-network", AnyView(PoolNetworkView(poolID: "local", computer: "Fixture computer", connection: workspace.connectionID).environment(workspace))))
        return panels
    }
}

private actor UpstreamApprovalFixture: DiscoboxClient {
    private let base = DemoClient()
    private let items: [ApprovalItem]
    init() {
        let text = #"""
        {"approvalRequests":[
          {"kind":"credential","credential":{"id":"modern","sandboxId":"demo-ui","status":"pending","name":"Project API","envName":"TOKEN","ttlSeconds":1800,"justification":"Read project issues and let a child box read the same project.","use":{"routes":[{"hosts":["api.example.test"],"methods":["GET"],"paths":["/issues/**"]},{"hosts":["api.example.test"],"paths":["/admin/**"],"blocked":true}]},"delegate":{"routes":[{"hosts":["mcp.example.test"],"mcp":{"tools":["read_*"]}}]}}},
          {"kind":"apiAccess","apiAccess":{"id":"api","requesterSandboxId":"demo-ui","status":"pending","justification":"Create child boxes to investigate the issue."}},
          {"kind":"adoption","adoption":{"id":"adopt","requesterSandboxId":"demo-ui","childSandboxId":"demo-api","childName":"API worker","readOnly":true,"status":"pending","justification":"Inspect the worker's findings."}},
          {"kind":"refresh","refresh":{"id":"refresh","sandboxId":"demo-ui","secretId":"token","secretName":"Project API","status":"pending","cause":"stale"}}
        ]}
        """#
        items = try! JSONDecoder().decode(ApprovalInbox.self, from: Data(text.utf8)).approvalRequests
    }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .approvals {
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(items.map { .object(["kind": .string($0.kind), $0.kind: $0.request]) })]))
        }
        if request.operation == .approvalContext {
            return try JSONEncoder().encode(JSONValue.object([
                "request": items.first { $0.id == request.requestID }?.request ?? .null,
                "secrets": .array([.object(["id": .string("token"), "name": .string("Project API"), "maxBindingTTLSeconds": .number(3600), "routes": .array([.object(["hosts": .array([.string("api.example.test")])])])])]),
                "held": .array([]), "bindings": .array([]), "fingerprint": .string("fixture-review"),
                "usePlan": .object(["Steps": .array([])]), "delegatePlan": .object(["Steps": .array([])])
            ]))
        }
        return try await base.perform(request)
    }
}
