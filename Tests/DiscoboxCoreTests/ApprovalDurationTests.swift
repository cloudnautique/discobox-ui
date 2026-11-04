import Foundation
import Testing
@testable import DiscoboxCore

@Test func automaticApprovalOmitsLifetimeRatherThanSendingRequestedDurationOrForever() throws {
    #expect(try ApprovalDuration.fields(ApprovalDuration.automatic, kind: "credential", maximum: 1800).isEmpty)
    #expect(try ApprovalDuration.fields("1800", kind: "credential", maximum: 1800) == ["grantTTLSeconds": .number(1800)])
    for duration in ["7200", "0", "-1", "not a duration", "1800.5", "999999999999999999999999999"] {
        #expect(throws: DiscoboxError.self) { try ApprovalDuration.fields(duration, kind: "credential", maximum: 1800) }
    }
    #expect(try ApprovalDuration.fields("7200", kind: "credential", maximum: 0) == ["grantTTLSeconds": .number(7200)])
    #expect(try ApprovalDuration.fields("0", kind: "credential", maximum: 0) == ["grantTTLSeconds": .number(0)])
}

@Test func trustApprovalStillRequiresAnExplicitBoundedDuration() throws {
    for value in [ApprovalDuration.automatic, "0", "2592001"] {
        #expect(throws: DiscoboxError.self) { try ApprovalDuration.fields(value, kind: "trust") }
    }
    #expect(try ApprovalDuration.fields("2592000", kind: "trust") == ["grantTTLSeconds": .number(2592000)])
}

@Test func credentialLimitsFollowSelectionAndWellKnownBindingWithoutGuessingByNameOrHost() {
    let request: JSONValue = .object(["wellKnownId": .string("com.example.repo")])
    let short: JSONValue = .object(["id": .string("short"), "wellKnownId": .string("com.example.repo"), "maxGrantTTLSeconds": .number(1800)])
    let long: JSONValue = .object(["id": .string("long"), "maxGrantTTLSeconds": .number(7200)])
    let all = [short, long]
    #expect(ApprovalDuration.selectedSecret(id: "", request: request, secrets: all) == short)
    #expect(ApprovalDuration.selectedSecret(id: "long", request: request, secrets: all) == long)
    #expect(ApprovalDuration.selectedSecret(id: "deleted", request: request, secrets: all) == .null)
    #expect(ApprovalDuration.selectedSecret(id: "", request: .object(["name": .string("short")]), secrets: all) == .null)
    #expect(ApprovalDuration.selectedSecret(id: "", request: request, secrets: [short, short]) == .null)
}

@MainActor @Test func twoHourNotificationRequestApprovesWithinThirtyMinuteSecretCap() async throws {
    let client = CappedApprovalFixture()
    let workspace = Workspace()
    await workspace.connect(client: client, label: "Capped fixture", demo: true)
    await workspace.refreshApprovals()
    let item = try #require(workspace.approvals.first)
    let notice = ApprovalNotice(id: "fixture", computerID: "fixture", connection: workspace.connectionID, item: item)
    #expect(try await notice.respond(.approve, workspace: workspace))
    #expect(await client.grantedSeconds == 1800)
    let answer = try #require(await client.answers.first)
    #expect(answer.payload?["grantTTLSeconds"] == .null)
    #expect(answer.payload?["secretMaxGrantTTLSeconds"] == .null)
    #expect(answer.payload?["rule"] == .null)
    #expect(answer.payload?["policy"] == item.request["policy"])
    #expect(workspace.approvals.isEmpty)
}

@MainActor @Test func automaticFormApprovalUsesServerCapAndExplicitShorterChoiceIsPreserved() async throws {
    for duration in [ApprovalDuration.automatic, "900"] {
        let client = CappedApprovalFixture(), workspace = Workspace()
        await workspace.connect(client: client, label: "Capped fixture", demo: true)
        await workspace.refreshApprovals()
        let item = try #require(workspace.approvals.first)
        var fields = try ApprovalDuration.fields(duration, kind: "credential", maximum: 1800)
        fields["policy"] = item.request["policy"]
        try await workspace.answer(item, action: "approve", payload: .object(fields))
        #expect(await client.grantedSeconds == (duration == ApprovalDuration.automatic ? 1800 : 900))
    }
}

private actor CappedApprovalFixture: DiscoboxClient {
    private let demo = DemoClient()
    private var pending = true
    private(set) var answers: [BridgeRequest] = []
    private(set) var grantedSeconds: Double?
    private let request: JSONValue = .object([
        "id": .string("capped-request"), "sandboxId": .string("demo-ui"), "status": .string("pending"),
        "name": .string("Repository"), "wellKnownId": .string("com.example.repo"), "grantTTLSeconds": .number(7200),
        "policy": .object(["resolved": .object(["repo": .string("example/project")])])
    ])
    func perform(_ message: BridgeRequest) async throws -> Data {
        if message.operation == .approvals {
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(pending ? [.object(["kind": .string("credential"), "credential": request])] : [])]))
        }
        if message.operation == .answer {
            let named = message.payload?["grantTTLSeconds"].number
            if let named, named == 0 || named > 1800 { throw DiscoboxError("HTTP 400: requested duration exceeds the credential's 30-minute limit") }
            grantedSeconds = named ?? min(request["grantTTLSeconds"].number!, 1800)
            answers.append(message); pending = false
            return Data("{}".utf8)
        }
        return try await demo.perform(message)
    }
}
