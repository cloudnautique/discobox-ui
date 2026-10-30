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

@Test func notificationApprovalPreservesRequestedAccessWithoutRulesOrCredentialEdits() throws {
    let item = noticeItem()
    let body = try #require(item.notificationApprovalPayload)
    #expect(body == .object(["grantTTLSeconds": .number(900), "policy": item.request["policy"]]))
    #expect(noticeItem(["grantTTLSeconds": .null]).notificationApprovalPayload?["grantTTLSeconds"] == .number(3600))
    for changes: [String: JSONValue] in [
        ["reason": .string("refresh")], ["reason": .string("future")], ["purpose": .string("delegate")],
        ["grantTTLSeconds": .number(0)], ["grantTTLSeconds": .number(-1)], ["grantTTLSeconds": .number(0.5)],
        ["grantTTLSeconds": .number(.infinity)], ["grantTTLSeconds": .string("900")], ["status": .string("granted")]
    ] { #expect(noticeItem(changes).notificationApprovalPayload == nil) }
    #expect(noticeItem(kind: "trust").notificationApprovalPayload == nil)
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
    let workspace = Workspace(), client = NoticeFixture(), inbox = ApprovalNoticeInbox()
    await workspace.connect(client: client, label: "fixture")
    await workspace.refreshApprovals()
    let notice = try #require(inbox.update(computerID: "local", connection: workspace.connectionID, items: workspace.approvals).added.first)
    #expect(try await !notice.respond(.later, workspace: workspace))
    #expect(await client.answers.isEmpty)
    #expect(workspace.approvals.count == 1)
    #expect(inbox.update(computerID: "local", connection: workspace.connectionID, items: workspace.approvals).added.isEmpty)
    await client.resolve()
    await workspace.refreshApprovals()
    #expect(inbox.update(computerID: "local", connection: workspace.connectionID, items: workspace.approvals).removed == [notice.id])
}

@MainActor @Test func notificationAnswerTargetsOriginalHostWithRequestedPolicy() async throws {
    let connections = Connections(polling: false), localClient = NoticeFixture(), remoteClient = NoticeFixture()
    let local = try await connections.connect(.thisComputer) { localClient }
    let remote = try await connections.connect(.init(name: "Other", endpoint: "https://other.example.invalid")) { remoteClient }
    await local.workspace.refreshApprovals(); await remote.workspace.refreshApprovals()
    let inbox = ApprovalNoticeInbox()
    let notice = try #require(inbox.update(computerID: local.id, connection: local.workspace.connectionID, items: local.workspace.approvals).added.first)
    #expect(connections.activeID == remote.id)
    #expect(try await notice.respond(.approve, workspace: local.workspace))
    let answer = try #require(await localClient.answers.first)
    #expect(answer.action == "approve")
    #expect(answer.requestID == notice.item.id)
    #expect(answer.payload == notice.item.notificationApprovalPayload)
    #expect(await remoteClient.answers.isEmpty)
    #expect(connections.activeID == remote.id)
    connections.disconnectAll()
}

@MainActor @Test func staleOrUnreachableNotificationNeverSubmits() async throws {
    for failure in ["changed", "resolved", "refresh-failed", "reconnected", "disconnected", "wrong-host"] {
        let workspace = Workspace(), client = NoticeFixture(), inbox = ApprovalNoticeInbox()
        await workspace.connect(client: client, label: "fixture")
        await workspace.refreshApprovals()
        let notice = try #require(inbox.update(computerID: "local", connection: workspace.connectionID, items: workspace.approvals).added.first)
        switch failure {
        case "changed": await client.change()
        case "resolved": await client.resolve()
        case "refresh-failed": await client.fail()
        case "reconnected": workspace.disconnect(); await workspace.connect(client: client, label: "reconnected")
        case "disconnected": workspace.disconnect()
        default: break
        }
        let other = Workspace()
        if failure == "wrong-host" { await other.connect(client: NoticeFixture(), label: "other") }
        await #expect(throws: (any Error).self) { try await notice.respond(.approve, workspace: failure == "wrong-host" ? other : workspace) }
        #expect(await client.answers.isEmpty)
        workspace.disconnect(); other.disconnect()
    }
}

@MainActor @Test func notificationsOpenFormForChoicesAndDenyWithoutGranting() async throws {
    for item in [noticeItem(kind: "trust"), noticeItem(["reason": .string("refresh")]), noticeItem(["purpose": .string("delegate")])] {
        let workspace = Workspace(), client = NoticeFixture(item: item), inbox = ApprovalNoticeInbox()
        await workspace.connect(client: client, label: "fixture")
        await workspace.refreshApprovals()
        let notice = try #require(inbox.update(computerID: "local", connection: workspace.connectionID, items: workspace.approvals).added.first)
        #expect(try await !notice.respond(.open, workspace: workspace))
        #expect(try await !notice.respond(.approve, workspace: workspace))
        #expect(await client.answers.isEmpty)
        #expect(try await notice.respond(.deny, workspace: workspace))
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
