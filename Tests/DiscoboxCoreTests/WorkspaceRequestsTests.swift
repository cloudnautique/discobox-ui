import Foundation
import Testing
@testable import DiscoboxCore

@Test func approvalAnswersOwnTheirActionAndWirePayload() throws {
    #expect(ApprovalAnswer.deny.action == "deny" && ApprovalAnswer.approve.action == "approve")
    #expect(try ApprovalAnswer.deny.payload() == .object([:]))
    #expect(try ApprovalAnswer.approve.payload() == .object([:]))
    let refresh = ApprovalAnswer.refresh(token: "replacement")
    #expect(refresh.action == "refresh")
    #expect(try refresh.payload() == .object(["value": .string("replacement"), "via": .string("entered")]))
    #expect(throws: DiscoboxError.self) { try ApprovalAnswer.refresh(token: "").payload() }

    let ca: JSONValue = .object(["isCA": .bool(true), "sha256": .string("ca-hash"), "spkiSha256": .string("ca-key")])
    let leaf: JSONValue = .object(["isCA": .bool(false), "sha256": .string("leaf-hash"), "spkiSha256": .string("leaf-key")])
    #expect(try ApprovalAnswer.trust(certificate: ca, duration: "3600").payload()["pin"] == .object(["kind": .string("ca"), "sha256": .string("ca-hash")]))
    #expect(try ApprovalAnswer.trust(certificate: leaf, duration: "3600").payload()["pin"] == .object(["kind": .string("leaf-spki"), "sha256": .string("leaf-key")]))
    #expect(throws: DiscoboxError.self) { try ApprovalAnswer.trust(certificate: .object(["isCA": .bool(false)]), duration: "3600").payload() }

    let request: JSONValue = .object(["policy": .object(["resolved": .object(["repo": .string("org/repo")])])])
    #expect(try ApprovalAnswer.credential(request: request, secretID: "s", duration: "900", maximum: 3600).payload()
            == LegacyCredentialDecision.payload(request: request, secretID: "s", duration: "900", maximum: 3600))
    let reviewed = ApprovalAnswer.reviewedCredential(approval: .object(["secretId": .string("s")]), contextFingerprint: .string("f"))
    #expect(reviewed.action == "approve")
    #expect(try reviewed.payload() == .object(["approval": .object(["secretId": .string("s")]), "contextFingerprint": .string("f")]))
    #expect(throws: DiscoboxError.self) { try ApprovalAnswer.reviewedCredential(approval: .object([:]), contextFingerprint: .null).payload() }
}

@Test func auditRecordReferencesNeedAPoolAndRecord() {
    #expect(AuditRecordReference("http/pool-a/http_42") == AuditRecordReference("http/pool-a/http_42"))
    #expect(AuditRecordReference("http/pool-a/http_42")?.pool == "pool-a")
    #expect(AuditRecordReference("http/pool-a/http_42")?.record == "http_42")
    #expect(AuditRecordReference("http/pool-a") == nil)
    #expect(AuditRecordReference("http//http_42") == nil)
}

@MainActor @Test func typedRequestsAreNeverSentToALaterConnection() async throws {
    let client = RecordingClient(), workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    let stale = UUID()
    await #expect(throws: DiscoboxError.self) { try await workspace.deleteSecret("secret", connection: stale) }
    await #expect(throws: DiscoboxError.self) { _ = try await workspace.updatePoolProxy("pool", payload: .object([:]), connection: stale) }
    #expect(await client.sent.isEmpty)

    try await workspace.deleteSecret("secret", connection: workspace.connectionID)
    let sent = try #require(await client.sent.last)
    #expect(sent.operation == .deleteSecret && sent.secretID == "secret" && sent.requestID == nil)
    let record = try #require(AuditRecordReference("http/pool-a/http_42"))
    _ = try await workspace.auditBody(record, part: "response", box: "demo-api", connection: workspace.connectionID)
    let audit = try #require(await client.sent.last)
    #expect(audit.operation == .auditBody && audit.sandboxID == "demo-api" && audit.poolID == "pool-a" && audit.recordID == "http_42" && audit.localPath == nil)
}

@MainActor @Test func aReplyAfterAReconnectIsNotReturned() async throws {
    let client = RecordingClient(), workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    let connection = workspace.connectionID
    await client.onPerform { _ in await MainActor.run { workspace.disconnect() } }
    await #expect(throws: DiscoboxError.self) { _ = try await workspace.poolConfiguration("pool", connection: connection) }
    #expect(await client.sent.count == 1)
}

@MainActor @Test func answerCanBeWithdrawnAfterValidation() async throws {
    let client = RecordingClient(), workspace = Workspace()
    await workspace.connect(client: client, label: "fixture", demo: true)
    await workspace.refreshApprovals()
    let item = try #require(workspace.approvals.first)
    let withdrawn = try await workspace.answer(item, .deny, connection: workspace.connectionID, proceed: { false })
    #expect(withdrawn == nil)
    #expect(await !client.sent.contains { $0.operation == .answer })
    var receipt: JSONValue?
    try await workspace.answer(item, .deny, connection: workspace.connectionID, onAccepted: { receipt = $0 })
    #expect(receipt != nil)
    #expect(await client.sent.filter { $0.operation == .answer }.map(\.action) == ["deny"])
    await #expect(throws: DiscoboxError.self) { _ = try await workspace.answer(item, .refresh(token: ""), connection: workspace.connectionID) }
}

private actor RecordingClient: DiscoboxClient {
    private let demo = DemoClient(pendingRequests: true)
    private(set) var sent: [BridgeRequest] = []
    private var hook: (@Sendable (BridgeRequest) async -> Void)?
    func onPerform(_ hook: @escaping @Sendable (BridgeRequest) async -> Void) { self.hook = hook }
    func perform(_ request: BridgeRequest) async throws -> Data {
        let polling: Set<BridgeRequest.Operation> = [.defaultProject, .sandboxes, .execs, .services, .screen, .approvals, .harnesses, .secrets]
        if !polling.contains(request.operation) { sent.append(request) }
        if let hook, !polling.contains(request.operation) { await hook(request) }
        return try await demo.perform(request)
    }
}
