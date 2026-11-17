import Foundation
import Observation

/// Review state for structured credential binding requests. A decision is
/// sendable only for the draft the server last previewed and fingerprinted.
@MainActor @Observable public final class BindingApprovalReview {
    public let lifecycle: ApprovalReviewLifecycle
    public var item: ApprovalItem { lifecycle.item }
    /// The server's last preview: limits, holdings, conflicts and fingerprint.
    public private(set) var context: JSONValue = .null
    public var secretID = ""
    public var use = CredentialPartDecision() {
        didSet {
            // Sharing follows the use grant's lifetime while use is approved.
            if use.decision == "approve" && (use.duration != oldValue.duration || oldValue.decision != "approve") { delegate.duration = use.duration }
        }
    }
    public var delegate = CredentialPartDecision()
    public var creating = false { didSet { if !creating { newValue = "" } } }
    public var newName: String
    public var newValue = ""
    /// The draft the current `context` previewed.
    public private(set) var contextDraft = ""

    public init(_ item: ApprovalItem, in session: ConnectionSession) {
        lifecycle = ApprovalReviewLifecycle(item: item, session: session, phase: .loading)
        let request = item.request
        // Preview drafts only. Only an explicit Approve action sends them;
        // opening the form never grants access.
        var use = CredentialPartDecision(), delegate = CredentialPartDecision()
        if request["use"] != .null { use.decision = "approve" }
        if request["delegate"] != .null { delegate.decision = "approve" }
        use.mode = request["use"]["add"] == .bool(true) ? "add" : "replace"
        newName = request["name"].string
        self.use = use; self.delegate = delegate
    }

    public var request: JSONValue { item.request }
    public var secret: JSONValue { context["secrets"].array.first { $0["id"].string == secretID } ?? .null }
    public var payload: JSONValue? { try? CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate) }
    public var validation: String? {
        if creating { return nil }
        if secretID.isEmpty { return "Choose an existing credential or add a new one." }
        do { _ = try CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate); return nil }
        catch { return error.localizedDescription }
    }
    public var draftKey: String { (payload?.pretty ?? "") + secretID + "|" + String(creating) }
    /// Changes whenever a fresh preview may be needed.
    public var previewKey: String { draftKey + "|" + String(lifecycle.isBusy) }
    public var conflicts: [JSONValue] { context["conflicts"].array }
    public var contextMatchesDraft: Bool { contextDraft == draftKey }
    public var approvesUse: Bool { request["use"] != .null && use.decision == "approve" }
    public var approvesSharing: Bool { request["delegate"] != .null && delegate.decision == "approve" }
    public var hasApproval: Bool { approvesUse || approvesSharing }
    public var pinned: Bool {
        let held = CredentialDecision.holder(request: request, held: context["held"].array)
        return held["from"].string == "sandbox" && held["fromId"] == request["sandboxId"]
    }
    public var requiresReload: Bool { lifecycle.phase == .uncertain }
    public var canApprove: Bool {
        lifecycle.phase == .review && !lifecycle.isResolved && contextMatchesDraft && !creating && hasApproval
            && payload != nil && conflicts.isEmpty && !context["fingerprint"].string.isEmpty
    }
    public var canStoreCredential: Bool { lifecycle.phase == .review && creating && !newName.isEmpty && !newValue.isEmpty }
    /// A denial needs no receipt; the form dismisses once it is recorded.
    public var dismissesAfterReceipt: Bool { lifecycle.phase == .recorded && lifecycle.receiptAction == "deny" }
    public var applyTitle: String {
        if approvesUse && approvesSharing { return "Approve use & sharing" }
        if approvesSharing { return "Approve sharing" }
        return request["delegate"] != .null && approvesUse ? "Approve use only" : "Approve"
    }
    public var footerSummary: String {
        if creating { return "Save the new credential before approving. Deny and Later remain available." }
        if !hasApproval { return "Use Deny to reject the entire request. Existing access stays unchanged." }
        if approvesSharing {
            return approvesUse ? "Approve grants the requested use and sharing with child boxes. Credential limits still apply." : "Approve grants sharing with child boxes. It does not approve use in this box."
        }
        return request["delegate"] != .null ? "Approve grants use only. The sharing part is denied; existing sharing grants stay unchanged." : "Approve grants only this request’s access, within the credential’s limits. Deny grants no new access."
    }

    /// Initial read: limits, holdings and the default credential.
    public func load() async { await reload(selectDefault: true) }

    /// Previews the current draft when it changed. Superseded reads are dropped.
    public func refreshPreview() async {
        guard lifecycle.phase == .review || lifecycle.phase == .loading, !creating, payload != nil else { return }
        await reload(selectDefault: false)
    }

    public func reload(selectDefault: Bool = false) async {
        let requestedDraft = draftKey, preview = payload
        guard let token = lifecycle.beginRead() else { return }
        do {
            let result = try await lifecycle.store.context(item: item, payload: preview)
            guard lifecycle.owns(token) else { return }
            guard result["request"] == request else { throw DiscoboxError("The request changed. Reopen it from the current inbox.") }
            context = result
            contextDraft = requestedDraft
            if selectDefault && secretID.isEmpty {
                secretID = CredentialDecision.holder(request: request, held: result["held"].array)["secretId"].string
                if secretID.isEmpty {
                    let matching = result["secrets"].array.filter { !request["wellKnownId"].string.isEmpty && $0["wellKnownId"] == request["wellKnownId"] }
                    if matching.count == 1 { secretID = matching[0]["id"].string }
                }
            }
            lifecycle.finishRead(token)
        } catch {
            if lifecycle.owns(token) { contextDraft = "" }
            lifecycle.finishRead(token, failure: error)
        }
    }

    /// Explicit draft edit after a binding conflict; it needs a fresh preview.
    public func addBesideExistingAccess() { use.mode = "add" }

    @discardableResult public func storeCredential() -> Task<Void, Never>? {
        guard canStoreCredential else { return nil }
        let body: JSONValue
        do { body = try TokenCredentialPayload.current(name: newName, value: newValue, routes: request["use"]["routes"].array + request["delegate"]["routes"].array) }
        catch { lifecycle.error = error.localizedDescription; return nil }
        return Task {
            defer { newValue = "" }
            guard let id = await lifecycle.storeCredential(body) else { return }
            secretID = id; creating = false
            await reload()
        }
    }

    @discardableResult public func submit(deny: Bool) -> Task<Void, Never>? {
        if deny { return lifecycle.submit(.deny) }
        guard canApprove, let decision = payload else { return nil }
        return lifecycle.submit(.reviewedCredential(approval: decision, contextFingerprint: context["fingerprint"]))
    }

    public func close() { lifecycle.close(); newValue = "" }
}
