import Foundation
import Testing
@testable import DiscoboxCore

@MainActor @Test func boxActionReceiptIsDeliveredBeforeSlowInventoryRefresh() async throws {
    let client = ReceiptFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Receipt fixture", demo: true)
    await client.holdRefresh()
    var accepted = false, returned = false
    let task = Task {
        try await workspace.performBoxAction(.archive, boxID: "demo-api", connection: workspace.connectionID, onAccepted: { accepted = true })
        returned = true
    }
    try await waitForReceiptRefresh(client)
    #expect(accepted && !returned)
    #expect(await client.writes == 1)
    await client.release()
    try await task.value
    #expect(returned && workspace.pendingBoxActions.isEmpty)
}

@MainActor @Test func approvalReceiptRemovesRequestBeforeSlowInboxRefresh() async throws {
    let client = ReceiptFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Receipt fixture", demo: true)
    await workspace.refreshApprovals()
    let item = try #require(workspace.approvals.first)
    await client.holdRefresh()
    var accepted = false, returned = false
    let task = Task {
        try await workspace.answer(item, action: "deny", payload: .object([:]), onAccepted: {
            #expect(!workspace.approvals.contains { $0.id == item.id })
            accepted = true
        })
        returned = true
    }
    try await waitForReceiptRefresh(client)
    #expect(accepted && !returned)
    #expect(await client.writes == 1)
    await client.release()
    try await task.value
    #expect(returned)
}

@MainActor @Test func notificationReceiptIsDeliveredBeforeSlowInboxRefresh() async throws {
    let client = ReceiptFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Receipt fixture", demo: true)
    await workspace.refreshApprovals()
    let item = try #require(workspace.approvals.first)
    let notice = ApprovalNotice(id: "receipt", computerID: "fixture", connection: workspace.connectionID, item: item)
    await client.holdRefresh()
    var accepted = false
    let task = Task { try await notice.respond(.deny, workspace: workspace, onAccepted: { accepted = true }) }
    try await waitForReceiptRefresh(client)
    #expect(accepted)
    #expect(await client.writes == 1)
    await client.release()
    #expect(try await task.value)
}

@MainActor @Test func structuredApprovalReceiptReleasesQueueBeforeStalledRead() async throws {
    let client = ReceiptFixture(), workspace = Workspace()
    await workspace.connect(client: client, label: "Receipt fixture", demo: true)
    defer { workspace.disconnect() }
    await workspace.refreshApprovals()
    let queue = ApprovalQueue(workspace: workspace, boxID: nil)
    queue.synchronize(); queue.reviewSelected()
    let item = try #require(queue.reviewing)
    await client.holdRefresh()
    var accepted = false
    let task = Task {
        try await workspace.answerWithReceipt(item, action: "deny", payload: .object([:]), onAccepted: { _ in
            accepted = true; queue.back()
        })
    }
    try await waitForReceiptRefresh(client)
    #expect(accepted && queue.reviewing == nil && queue.requests.isEmpty)
    #expect(await client.writes == 1)
    await client.release()
    _ = try await task.value
}

@MainActor @Test func rejectedMutationDoesNotReportAcceptanceOrRetry() async throws {
    let client = ReceiptFixture(fail: true), workspace = Workspace()
    await workspace.connect(client: client, label: "Receipt fixture", demo: true)
    var accepted = false
    await #expect(throws: DiscoboxError.self) {
        try await workspace.performBoxAction(.archive, boxID: "demo-api", connection: workspace.connectionID, onAccepted: { accepted = true })
    }
    #expect(!accepted && workspace.pendingBoxActions.isEmpty)
    #expect(await client.writes == 1)
}

private func waitForReceiptRefresh(_ client: ReceiptFixture) async throws {
    for _ in 0..<200 {
        if await client.waiting { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DiscoboxError("Receipt fixture never reached its follow-up refresh")
}

private actor ReceiptFixture: DiscoboxClient {
    private let demo = DemoClient(pendingRequests: true)
    private let fail: Bool
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    private(set) var writes = 0
    init(fail: Bool = false) { self.fail = fail }
    func holdRefresh() { hold = true }
    func release() { hold = false; continuation?.resume(); continuation = nil; waiting = false }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .boxAction || request.operation == .answer {
            writes += 1
            if fail { throw DiscoboxError("Fixture refusal") }
        } else if hold && writes > 0 && [.sandboxes, .approvals].contains(request.operation) {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await demo.perform(request)
    }
}
