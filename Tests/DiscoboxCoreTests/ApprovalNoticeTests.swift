import Foundation
import Testing
@testable import DiscoboxCore

private func noticeItem(_ changes: [String: JSONValue] = [:], kind: String = "credential") -> ApprovalItem {
    var body: [String: JSONValue] = ["id": .string("same-request"), "sandboxId": .string("demo-ui"), "status": .string("pending"),
                                    "name": .string("GitHub"), "grantTTLSeconds": .number(900),
                                    "policy": .object(["future": .object(["scope": .string("read")]), "resolved": .object(["repo": .string("org/repo")])])]
    for (key, value) in changes { body[key] = value }
    return .init(kind: kind, credential: kind == "credential" ? .object(body) : nil, trust: kind == "trust" ? .object(body) : nil)
}

@Test func notificationApprovalAlwaysRequiresTheCurrentReviewForm() {
    for changes: [String: JSONValue] in [[:], ["grantTTLSeconds": .null], ["purpose": .string("delegate")], ["reason": .string("refresh")]] {
        #expect(noticeItem(changes).notificationApprovalAnswer == nil)
    }
    #expect(noticeItem(kind: "trust").notificationApprovalAnswer == nil)
}

@MainActor @Test func noticesDeduplicateAndScopeIdenticalRequestIDsByHostAndConnection() throws {
    let inbox = ApprovalNoticeInbox(), local = UUID(), remote = UUID(), item = noticeItem()
    let a = try #require(inbox.update(computerID: "local", connection: local, items: [item]).added.first)
    #expect(inbox.update(computerID: "local", connection: local, items: [item]).added.isEmpty)
    let b = try #require(inbox.update(computerID: "remote", connection: remote, items: [item]).added.first)
    #expect(a.id != b.id)
    #expect(inbox.claim(a.id) == a)
    #expect(inbox.claim(a.id) == nil)
    inbox.finish(a.id)
    #expect(inbox.claim(a.id) == a)
    let changed = inbox.update(computerID: "local", connection: local, items: [noticeItem(["grantTTLSeconds": .number(86400)])])
    #expect(changed.removed == [a.id])
    #expect(inbox.notice(a.id) == nil)
    #expect(inbox.notice(b.id) == b)
    let reconnected = inbox.update(computerID: "remote", connection: UUID(), items: [item])
    #expect(reconnected.removed == [b.id])
    #expect(reconnected.added.count == 1)
    #expect(inbox.reset().count == 2)
    #expect(inbox.notice(b.id) == nil)
}

@MainActor @Test func resolvedNoticesDisappearAndLaterDoesNotAnswerOrRepeat() async throws {
    let workspace = ConnectionSession(), client = NoticeFixture(), inbox = ApprovalNoticeInbox()
    await workspace.connect(client: client, label: "fixture")
    await workspace.approvalStore.refreshApprovals()
    let notice = try #require(inbox.update(computerID: "local", connection: workspace.connectionState.connectionID, items: workspace.approvalStore.approvals).added.first)
    #expect(try await !notice.respond(.later, approvals: workspace.approvalStore))
    #expect(await client.answers.isEmpty)
    #expect(workspace.approvalStore.approvals.count == 1)
    #expect(inbox.update(computerID: "local", connection: workspace.connectionState.connectionID, items: workspace.approvalStore.approvals).added.isEmpty)
    await client.resolve()
    await workspace.approvalStore.refreshApprovals()
    #expect(inbox.update(computerID: "local", connection: workspace.connectionState.connectionID, items: workspace.approvalStore.approvals).removed == [notice.id])
}

@MainActor @Test func notificationAnswerTargetsOriginalHostWithRequestedPolicy() async throws {
    let connections = Connections(polling: false), localClient = NoticeFixture(), remoteClient = NoticeFixture()
    let local = try await connections.connect(.thisComputer) { localClient }
    let remote = try await connections.connect(.init(name: "Other", endpoint: "https://other.example.invalid")) { remoteClient }
    await local.approvalStore.refreshApprovals(); await remote.approvalStore.refreshApprovals()
    let inbox = ApprovalNoticeInbox()
    let notice = try #require(inbox.update(computerID: local.id, connection: local.connectionState.connectionID, items: local.approvalStore.approvals).added.first)
    #expect(connections.activeID == remote.id)
    #expect(try await !notice.respond(.approve, approvals: local.approvalStore))
    #expect(await localClient.answers.isEmpty)
    #expect(try await notice.respond(.deny, approvals: local.approvalStore))
    let answer = try #require(await localClient.answers.first)
    #expect(answer.action == "deny")
    #expect(answer.requestID == notice.item.id)
    #expect(answer.payload == .object([:]))
    #expect(await remoteClient.answers.isEmpty)
    #expect(connections.activeID == remote.id)
    connections.disconnectAll()
}

@MainActor @Test func staleOrUnreachableNotificationNeverSubmits() async throws {
    for failure in ["changed", "resolved", "refresh-failed", "reconnected", "disconnected", "wrong-host"] {
        let workspace = ConnectionSession(), client = NoticeFixture(), inbox = ApprovalNoticeInbox()
        await workspace.connect(client: client, label: "fixture")
        await workspace.approvalStore.refreshApprovals()
        let notice = try #require(inbox.update(computerID: "local", connection: workspace.connectionState.connectionID, items: workspace.approvalStore.approvals).added.first)
        switch failure {
        case "changed": await client.change()
        case "resolved": await client.resolve()
        case "refresh-failed": await client.fail()
        case "reconnected": workspace.disconnect(); await workspace.connect(client: client, label: "reconnected")
        case "disconnected": workspace.disconnect()
        default: break
        }
        let other = ConnectionSession()
        if failure == "wrong-host" { await other.connect(client: NoticeFixture(), label: "other") }
        await #expect(throws: (any Error).self) { try await notice.respond(.approve, approvals: failure == "wrong-host" ? other.approvalStore : workspace.approvalStore) }
        #expect(await client.answers.isEmpty)
        workspace.disconnect(); other.disconnect()
    }
}

@MainActor @Test func notificationsOpenFormForChoicesAndDenyWithoutGranting() async throws {
    for item in [noticeItem(kind: "trust"), noticeItem(["reason": .string("refresh")]), noticeItem(["purpose": .string("delegate")])] {
        let workspace = ConnectionSession(), client = NoticeFixture(item: item), inbox = ApprovalNoticeInbox()
        await workspace.connect(client: client, label: "fixture")
        await workspace.approvalStore.refreshApprovals()
        let notice = try #require(inbox.update(computerID: "local", connection: workspace.connectionState.connectionID, items: workspace.approvalStore.approvals).added.first)
        #expect(try await !notice.respond(.open, approvals: workspace.approvalStore))
        #expect(try await !notice.respond(.approve, approvals: workspace.approvalStore))
        #expect(await client.answers.isEmpty)
        #expect(try await notice.respond(.deny, approvals: workspace.approvalStore))
        let answer = try #require(await client.answers.first)
        #expect(answer.action == "deny")
        #expect(answer.kind == item.kind)
        #expect(answer.payload == .object([:]))
        workspace.disconnect()
    }
}

private actor NoticeFixture: DiscoboxClient {
    let demo = DemoClient()
    var item: ApprovalItem
    var pending = true
    var failRefresh = false
    var answers: [BridgeRequest] = []
    init(item: ApprovalItem = noticeItem()) { self.item = item }
    func resolve() { pending = false }
    func change() { item = noticeItem(["grantTTLSeconds": .number(86400)]) }
    func fail() { failRefresh = true }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .answer { answers.append(request); pending = false; return Data("{}".utf8) }
        if request.operation == .approvals {
            if failRefresh { throw DiscoboxError("Offline fixture") }
            let entries: [JSONValue] = pending ? [.object(["kind": .string(item.kind), item.kind: item.request])] : []
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(entries)]))
        }
        return try await demo.perform(request)
    }
}
