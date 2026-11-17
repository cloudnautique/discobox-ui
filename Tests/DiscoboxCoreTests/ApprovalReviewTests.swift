import Foundation
import Testing
@testable import DiscoboxCore

// Review models drive the approval lifecycle against a controllable fixture:
// any operation can be held mid-flight, and answers can fail after sending.

@MainActor private func session(_ client: ReviewFixture) async throws -> (ConnectionSession, (String) throws -> ApprovalItem) {
    let session = ConnectionSession()
    await session.connect(client: client, label: "Review fixture", demo: true)
    await session.approvalStore.refreshApprovals()
    return (session, { id in try #require(session.approvalStore.approvals.first { $0.id == id }) })
}

@MainActor private func eventually(line: Int = #line, _ condition: () async -> Bool) async throws {
    for _ in 0..<400 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
    throw DiscoboxError("Condition not reached at line \(line)")
}

@MainActor @Test func closingDuringDelayedMetadataOrPreviewAppliesNothing() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }

    let legacy = LegacyApprovalReview(try item("legacy"), in: workspace)
    await client.hold(.secrets)
    let loading = Task { await legacy.load() }
    try await eventually { await client.isWaiting(.secrets) }
    #expect(legacy.lifecycle.phase == .loading)
    legacy.close()
    await client.release(.secrets)
    await loading.value
    #expect(legacy.secrets.isEmpty && legacy.secret.isEmpty && legacy.lifecycle.error == nil)

    let binding = BindingApprovalReview(try item("binding"), in: workspace)
    await client.hold(.approvalContext)
    let previewing = Task { await binding.load() }
    try await eventually { await client.isWaiting(.approvalContext) }
    binding.close()
    await client.release(.approvalContext)
    await previewing.value
    #expect(binding.context == .null && binding.secretID.isEmpty && !binding.canApprove)
    #expect(await client.writes.isEmpty)
}

@MainActor @Test func closingDuringValidationNeverTransmitsInAnyFormat() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    let legacy = LegacyApprovalReview(try item("legacy"), in: workspace)
    await legacy.load()
    let binding = BindingApprovalReview(try item("binding"), in: workspace)
    await binding.load(); await binding.refreshPreview()
    let consent = ConsentApprovalReview(try item("refresh"), in: workspace)
    consent.reviewed = true; consent.value = "replacement-token"
    #expect(legacy.canApprove && binding.canApprove && consent.canApprove)

    let submissions: [(ApprovalReviewLifecycle, () -> Task<Void, Never>?, () -> Void)] = [
        (legacy.lifecycle, { legacy.submit(deny: false) }, { legacy.close() }),
        (binding.lifecycle, { binding.submit(deny: false) }, { binding.close() }),
        (consent.lifecycle, { consent.submit(approve: true) }, { consent.close() })
    ]
    for (lifecycle, submit, close) in submissions {
        await client.hold(.approvals)
        let task = try #require(submit())
        try await eventually { await client.isWaiting(.approvals) }
        #expect(lifecycle.phase == .validating)
        close()
        await client.release(.approvals)
        await task.value
        #expect(lifecycle.phase == .validating && lifecycle.receipt == nil)
    }
    #expect(consent.value.isEmpty)
    #expect(await client.writes.isEmpty)
    #expect(workspace.approvalStore.approvals.count == 4)
}

@MainActor @Test func legacyCredentialCreationStopsWhenClosedAfterValidation() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    let legacy = LegacyApprovalReview(try item("legacy"), in: workspace)
    await legacy.load()
    legacy.creating = true; legacy.newName = "New token"; legacy.value = "token-value"; legacy.host = "api.example.test"
    await client.hold(.approvals)
    let task = try #require(legacy.storeCredential())
    try await eventually { await client.isWaiting(.approvals) }
    legacy.close()
    #expect(legacy.value.isEmpty)
    await client.release(.approvals)
    await task.value
    #expect(await client.writes.isEmpty)

    // Open: stores once, selects it, and still sends no decision.
    let open = LegacyApprovalReview(try item("legacy"), in: workspace)
    await open.load()
    open.creating = true; open.newName = "New token"; open.value = "token-value"; open.host = "api.example.test"
    await open.storeCredential()?.value
    #expect(await client.writes == [.createSecret])
    #expect(open.secret == "created" && !open.creating && open.value.isEmpty && open.lifecycle.phase == .review)
}

@MainActor @Test func closingAfterSendCompletesOnceAndPublishesToTheInbox() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    let consent = ConsentApprovalReview(try item("api"), in: workspace)
    consent.reviewed = true
    await client.hold(.answer)
    let task = try #require(consent.submit(approve: true))
    try await eventually { await client.isWaiting(.answer) }
    #expect(consent.lifecycle.phase == .transmitting)
    consent.close()
    #expect(consent.submit(approve: true) == nil)
    await client.release(.answer)
    await task.value
    #expect(consent.lifecycle.phase == .recorded && consent.approved)
    #expect(await client.writes == [.answer])
    #expect(!workspace.approvalStore.approvals.contains { $0.id == "api" })
}

@MainActor @Test func uncertainFailureIsNeverRetriedAndReachesTheOwnerAfterClose() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    await client.failAnswers()

    let open = LegacyApprovalReview(try item("legacy"), in: workspace)
    await open.load()
    await open.submit(deny: true)?.value
    #expect(open.lifecycle.phase == .uncertain && open.lifecycle.error != nil)
    #expect(open.submit(deny: true) == nil && !open.canApprove)
    #expect(await client.writes == [.answer])
    #expect(workspace.selection.commandError == nil)

    await client.hold(.answer)
    let closed = BindingApprovalReview(try item("binding"), in: workspace)
    await closed.load()
    let task = try #require(closed.submit(deny: true))
    try await eventually { await client.isWaiting(.answer) }
    closed.close()
    await client.release(.answer)
    await task.value
    #expect(closed.lifecycle.phase == .uncertain && closed.requiresReload)
    #expect(workspace.selection.commandError?.contains("may have been recorded") == true)
    #expect(await client.writes == [.answer, .answer])

    // A fresh server read is required before deciding again.
    let consent = ConsentApprovalReview(try item("api"), in: workspace)
    consent.reviewed = true
    await consent.submit(approve: true)?.value
    #expect(consent.lifecycle.phase == .uncertain)
    await consent.recheck()
    #expect(consent.lifecycle.phase == .review && consent.lifecycle.error == nil)
    #expect(await client.writes.count == 3)
}

@MainActor @Test func replacedOrWithdrawnRequestsAreNotAnswered() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    let legacy = LegacyApprovalReview(try item("legacy"), in: workspace)
    await legacy.load()

    // Withdrawn during validation: nothing is sent and review resumes.
    await client.hold(.approvals)
    let task = try #require(legacy.submit(deny: false))
    try await eventually { await client.isWaiting(.approvals) }
    await client.withdraw("legacy")
    await client.release(.approvals)
    await task.value
    #expect(legacy.lifecycle.phase == .review && legacy.lifecycle.error != nil)

    // Replaced in the inbox: the reviewed request is resolved.
    let consent = ConsentApprovalReview(try item("api"), in: workspace)
    consent.reviewed = true
    await client.replace("api")
    await workspace.approvalStore.refreshApprovals()
    #expect(consent.lifecycle.isResolved && !consent.canApprove)
    #expect(consent.submit(approve: false) == nil)
    #expect(await client.writes.isEmpty)
}

@MainActor @Test func reconnectionDropsReadsAndRefusesDecisions() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    let binding = BindingApprovalReview(try item("binding"), in: workspace)
    await client.hold(.approvalContext)
    let loading = Task { await binding.load() }
    try await eventually { await client.isWaiting(.approvalContext) }
    workspace.disconnect()
    let replacement = ReviewFixture()
    await workspace.connect(client: replacement, label: "Same host again", demo: true)
    await workspace.approvalStore.refreshApprovals()
    await client.release(.approvalContext)
    await loading.value
    #expect(binding.context == .null && binding.lifecycle.isResolved)
    #expect(binding.submit(deny: true) == nil)
    #expect(await client.writes.isEmpty)
    #expect(await replacement.writes.isEmpty)
}

@MainActor @Test func draftChangedDuringPreviewNeedsAFreshPreview() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    let binding = BindingApprovalReview(try item("binding"), in: workspace)
    await binding.load()
    #expect(binding.secretID == "secret")
    await binding.refreshPreview()
    #expect(binding.canApprove)

    await client.hold(.approvalContext)
    let preview = Task { await binding.refreshPreview() }
    try await eventually { await client.isWaiting(.approvalContext) }
    binding.addBesideExistingAccess()
    await client.release(.approvalContext)
    await preview.value
    #expect(!binding.contextMatchesDraft && !binding.canApprove)
    #expect(binding.submit(deny: false) == nil)
    await binding.refreshPreview()
    #expect(binding.canApprove)
    #expect(await client.lastPreview["use"]["as"].string == "add")

    // A preview in flight when the decision starts cannot reopen review.
    await client.hold(.approvalContext)
    let stale = Task { await binding.refreshPreview() }
    try await eventually { await client.isWaiting(.approvalContext) }
    binding.use.duration = "900"
    let decision = binding.submit(deny: true)
    #expect(decision != nil)
    await client.release(.approvalContext)
    await stale.value
    await decision?.value
    #expect(binding.lifecycle.phase == .recorded && binding.dismissesAfterReceipt)
}

@MainActor @Test func duplicateSubmissionSendsOneFrozenDecision() async throws {
    let client = ReviewFixture()
    let (workspace, item) = try await session(client)
    defer { workspace.disconnect() }
    let consent = ConsentApprovalReview(try item("refresh"), in: workspace)
    consent.reviewed = true; consent.value = "first-token"
    await client.hold(.approvals)
    let first = try #require(consent.submit(approve: true))
    #expect(consent.submit(approve: true) == nil && consent.submit(approve: false) == nil)
    consent.value = "edited-during-validation"
    await client.release(.approvals)
    await first.value
    #expect(consent.lifecycle.phase == .recorded && consent.value.isEmpty)
    #expect(await client.writes == [.answer])
    #expect(await client.lastAnswer?["value"].string == "first-token")
}

private actor ReviewFixture: DiscoboxClient {
    private let demo = DemoClient()
    private var pending = ["legacy", "binding", "refresh", "api"]
    private var replaced: Set<String> = []
    private var held: Set<BridgeRequest.Operation> = []
    private var waiters: [BridgeRequest.Operation: CheckedContinuation<Void, Never>] = [:]
    private var failing = false
    private(set) var writes: [BridgeRequest.Operation] = []
    private(set) var lastPreview: JSONValue = .null
    private(set) var lastAnswer: JSONValue?

    func hold(_ operation: BridgeRequest.Operation) { held.insert(operation) }
    func release(_ operation: BridgeRequest.Operation) { held.remove(operation); waiters.removeValue(forKey: operation)?.resume() }
    func isWaiting(_ operation: BridgeRequest.Operation) -> Bool { waiters[operation] != nil }
    func failAnswers() { failing = true }
    func withdraw(_ id: String) { pending.removeAll { $0 == id } }
    func replace(_ id: String) { replaced.insert(id) }

    private func request(_ id: String) -> JSONValue {
        let reason: JSONValue = .string(replaced.contains(id) ? "Changed request" : "Original request")
        switch id {
        case "legacy":
            return .object(["kind": .string("credential"), "credential": .object(["id": .string(id), "sandboxId": .string("demo-ui"), "status": .string("pending"),
                "name": .string("Repository"), "wellKnownId": .string("fixture.repo"), "justification": reason, "policy": .object(["resolved": .object([:])])])])
        case "binding":
            return .object(["kind": .string("credential"), "credential": bindingAsk])
        case "refresh":
            return .object(["kind": .string("refresh"), "refresh": .object(["id": .string(id), "sandboxId": .string("demo-ui"), "secretId": .string("secret"), "status": .string("pending"), "justification": reason])])
        default:
            return .object(["kind": .string("apiAccess"), "apiAccess": .object(["id": .string(id), "requesterSandboxId": .string("demo-ui"), "status": .string("pending"), "justification": reason])])
        }
    }
    private let bindingAsk: JSONValue = .object(["id": .string("binding"), "sandboxId": .string("demo-ui"), "status": .string("pending"), "name": .string("Repository"),
        "wellKnownId": .string("fixture.repo"), "envName": .string("TOKEN"), "use": .object(["routes": .array([.object(["hosts": .array([.string("api.example.test")])])])])])

    func perform(_ message: BridgeRequest) async throws -> Data {
        if held.contains(message.operation) {
            await withCheckedContinuation { waiters[message.operation] = $0 }
        }
        switch message.operation {
        case .approvals:
            return try JSONEncoder().encode(JSONValue.object(["approvalRequests": .array(pending.map(request))]))
        case .secrets:
            return Data(#"{"secrets":[{"id":"secret","wellKnownId":"fixture.repo","maxGrantTTLSeconds":1800}]}"#.utf8)
        case .approvalContext:
            lastPreview = message.payload ?? .null
            return try JSONEncoder().encode(JSONValue.object(["request": bindingAsk, "fingerprint": .string("fixture-fingerprint"), "held": .array([]),
                "secrets": .array([.object(["id": .string("secret"), "wellKnownId": .string("fixture.repo"), "maxBindingTTLSeconds": .number(1800)])])]))
        case .answer:
            writes.append(.answer); lastAnswer = message.payload
            if failing { throw DiscoboxError("Fixture connection lost after sending") }
            pending.removeAll { $0 == message.requestID }
            return Data(#"{"recorded":true}"#.utf8)
        case .createSecret:
            writes.append(.createSecret)
            return Data(#"{"id":"created"}"#.utf8)
        default:
            return try await demo.perform(message)
        }
    }
}
