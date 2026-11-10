import Foundation
import Testing
@testable import DiscoboxCore

@MainActor @Test func approvalQueueReviewsThreeRequestsAndKeepsOtherBoxesSeparate() async throws {
    let client = ApprovalQueueFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Approval queue fixture", demo: true)
    defer { workspace.disconnect() }
    await workspace.refreshApprovals()
    let queue = ApprovalQueue(workspace: workspace, boxID: "demo-ui")
    queue.synchronize()
    #expect(queue.requests.count == 3)
    #expect(queue.selected?.id == "use-1")
    queue.reviewSelected()
    #expect(queue.reviewing?.intent == "Use in this box")
    queue.back()
    #expect(queue.requests.count == 3)
    #expect(await client.answers.isEmpty)
    for expected in ["use-1", "share", "use-2"] {
        queue.reviewSelected()
        let item = try #require(queue.reviewing)
        #expect(item.id == expected)
        let receipt = try await workspace.answerWithReceipt(item, action: "deny", payload: .object([:]), onAccepted: { result in
            #expect(result["recorded"] == .bool(true))
            #expect(!queue.requests.contains { $0.id == expected })
            queue.back()
        })
        #expect(receipt["recorded"] == .bool(true))
        #expect(queue.reviewing == nil)
    }
    #expect(queue.requests.isEmpty && queue.selection == nil)
    #expect(!workspace.approvals.contains { $0.boxID == "demo-ui" })
    #expect(workspace.approvals.map(\.id) == ["other-box"])
    #expect(await client.answers == ["use-1", "share", "use-2"])
}

@MainActor @Test func approvalQueueUsesLatestRowAndDoesNotRetargetAcrossConnections() async throws {
    let client = ApprovalQueueFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Approval queue fixture", demo: true)
    defer { workspace.disconnect() }
    await workspace.refreshApprovals()
    let queue = ApprovalQueue(workspace: workspace, boxID: "demo-ui")
    queue.synchronize()
    let previous = try #require(queue.selected)
    await client.changeReason()
    await workspace.refreshApprovals()
    queue.review(previous)
    #expect(queue.reviewing?.request["justification"].string == "Updated request")
    await client.withdraw("use-1")
    await workspace.refreshApprovals()
    queue.back()
    #expect(queue.selected?.id == "share")
    #expect(queue.selected?.intent == "Share with child boxes")
    #expect(queue.selected?.destinationSummary == "api.example.test")
    workspace.disconnect()
    await workspace.connect(client: ApprovalQueueFixture(), label: "Different host", demo: true)
    await workspace.refreshApprovals()
    queue.reviewSelected()
    #expect(!queue.valid && queue.requests.isEmpty && queue.reviewing == nil)
}

@MainActor @Test func approvalQueueKeepsFailedAnswersPendingWithoutRetrying() async throws {
    let client = ApprovalQueueFixture(fail: true), workspace = Workspace()
    await workspace.connect(client: client, label: "Refusal fixture", demo: true)
    defer { workspace.disconnect() }
    await workspace.refreshApprovals()
    let queue = ApprovalQueue(workspace: workspace, boxID: "demo-ui")
    queue.synchronize(); queue.reviewSelected()
    let item = try #require(queue.reviewing)
    var accepted = false
    await #expect(throws: DiscoboxError.self) {
        try await workspace.answerWithReceipt(item, action: "deny", payload: .object([:]), onAccepted: { _ in accepted = true })
    }
    #expect(!accepted && queue.requests.count == 3 && queue.reviewing == item)
    #expect(await client.answers == [item.id])
}

private actor ApprovalQueueFixture: DiscoboxClient {
    private let demo = DemoClient()
    private let fail: Bool
    private var pending = ["use-1", "share", "use-2", "other-box"]
    private var reason = "Read repository issues"
    private(set) var answers: [String] = []
    init(fail: Bool = false) { self.fail = fail }
    func changeReason() { reason = "Updated request" }
    func withdraw(_ id: String) { pending.removeAll { $0 == id } }
    func perform(_ message: BridgeRequest) async throws -> Data {
        if message.operation == .approvals {
            let items: [JSONValue] = pending.map { id in
                .object(["kind": .string("credential"), "credential": .object([
                    "id": .string(id), "sandboxId": .string(id == "other-box" ? "demo-api" : "demo-ui"),
                    "status": .string("pending"), "name": .string("Repository access"), "justification": .string(reason),
                    id == "share" ? "delegate" : "use": .object(["routes": .array([
                        .object(["hosts": .array([.string("api.example.test")])]),
                        .object(["hosts": .array([.string("blocked.example.test")]), "blocked": .bool(true)])
                    ])])
                ])])
            }
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(items)]))
        }
        if message.operation == .answer {
            let id = message.requestID ?? ""
            answers.append(id)
            if fail { throw DiscoboxError("Fixture refusal") }
            pending.removeAll { $0 == id }
            return Data(#"{"recorded":true}"#.utf8)
        }
        return try await demo.perform(message)
    }
}
