import Foundation
import Observation

/// Review state for old grant APIs and certificate pins. Its wire payload stays
/// separate from binding approvals; shared restrictions and auto-approval rules
/// are never edited as a side effect of approval.
@MainActor @Observable public final class LegacyApprovalReview {
    public let lifecycle: ApprovalReviewLifecycle
    public var item: ApprovalItem { lifecycle.item }
    public private(set) var secrets: [JSONValue] = []
    /// The chosen credential ID; empty selects the server-configured one.
    public var secret = ""
    public var duration: String
    /// A replacement token, or the token for an inline new credential.
    public var value = ""
    public var newName: String
    public var host: String
    public var creating = false { didSet { if !creating { value = "" } } }
    /// A certificate index into `certificates`, as text.
    public var pin = ""
    @ObservationIgnored private var reviewedRevision: String?

    public init(_ item: ApprovalItem, in session: ConnectionSession, initialDuration: String? = nil) {
        lifecycle = ApprovalReviewLifecycle(item: item, session: session, phase: item.kind == "credential" ? .loading : .review)
        let request = item.request
        let requested = request["grantTTLSeconds"].number ?? 3600
        let trustDuration = requested.isFinite && requested > 0 && requested < Double(Int.max) ? String(Int(requested)) : "3600"
        duration = initialDuration ?? (item.kind == "trust" ? trustDuration : ApprovalDuration.automatic)
        newName = request["name"].string
        host = request["hosts"].array.count == 1 ? request["hosts"].array[0].string : ""
    }

    public var request: JSONValue { item.request }
    public var isRefresh: Bool { request["reason"].string == "refresh" }
    public var certificates: [JSONValue] { request["observedChain"].array + (request["suppliedCA"] == .null ? [] : [request["suppliedCA"]]) }
    public var selectedSecret: JSONValue { ApprovalDuration.selectedSecret(id: secret, request: request, secrets: secrets) }
    public var maximum: Double? { item.kind == "credential" ? selectedSecret["maxGrantTTLSeconds"].number : nil }
    public var validation: String? {
        if isRefresh { return value.isEmpty ? "Enter a replacement token." : nil }
        do { _ = try ApprovalDuration.fields(duration, kind: item.kind, maximum: maximum); return nil }
        catch { return error.localizedDescription }
    }
    /// Any change to the reviewed draft clears the trust acknowledgment.
    private var revision: String { [secret, duration, pin, value, request.pretty, selectedSecret.pretty].joined(separator: "|") }
    public var reviewed: Bool {
        get { reviewedRevision == revision }
        set { reviewedRevision = newValue ? revision : nil }
    }
    public var canApprove: Bool {
        lifecycle.phase == .review && !lifecycle.isResolved && !creating && validation == nil
            && (item.kind != "trust" || reviewed && !pin.isEmpty)
    }
    public var canStoreCredential: Bool {
        lifecycle.phase == .review && creating && !newName.isEmpty && !value.isEmpty && !host.isEmpty
    }

    /// Reads credential metadata. Superseded or closed reads change nothing.
    public func load() async {
        guard item.kind == "credential" else { return }
        guard let token = lifecycle.beginRead() else { return }
        do {
            let loaded = try await lifecycle.store.approvalSecrets()
            guard lifecycle.owns(token) else { return }
            secrets = loaded
            let configured = ApprovalDuration.selectedSecret(id: secret, request: request, secrets: loaded)
            if secret.isEmpty, !configured["id"].string.isEmpty { secret = configured["id"].string }
            lifecycle.finishRead(token)
        } catch { lifecycle.finishRead(token, failure: error) }
    }

    /// After an unconfirmed write: read the inbox and metadata again.
    public func recheck() async {
        guard let token = await lifecycle.confirmPending() else { return }
        guard item.kind == "credential" else { lifecycle.finishRead(token); return }
        do {
            let loaded = try await lifecycle.store.approvalSecrets()
            guard lifecycle.owns(token) else { return }
            secrets = loaded
            lifecycle.finishRead(token)
        } catch { lifecycle.finishRead(token, failure: error) }
    }

    @discardableResult public func storeCredential() -> Task<Void, Never>? {
        guard canStoreCredential else { return nil }
        let body: JSONValue
        do { body = try TokenCredentialPayload.legacy(name: newName, value: value, host: host, maximum: 3600) }
        catch { lifecycle.error = error.localizedDescription; return nil }
        return Task {
            defer { value = "" }
            guard let id = await lifecycle.storeCredential(body) else { return }
            secret = id; creating = false
            await load()
        }
    }

    public func answer(deny: Bool) throws -> ApprovalAnswer {
        if deny { return .deny }
        if isRefresh { return .refresh(token: value) }
        if item.kind == "credential" { return .credential(request: request, secretID: secret, duration: duration, maximum: maximum) }
        if let index = Int(pin), certificates.indices.contains(index) { return .trust(certificate: certificates[index], duration: duration) }
        throw DiscoboxError("Choose a certificate to trust.")
    }

    @discardableResult public func submit(deny: Bool) -> Task<Void, Never>? {
        guard deny || canApprove else { return nil }
        let decision: ApprovalAnswer
        do { decision = try answer(deny: deny) } catch { lifecycle.error = error.localizedDescription; return nil }
        // The decision is a frozen value; the token copy is cleared when the operation ends.
        return lifecycle.submit(decision) { [weak self] in self?.value = "" }
    }

    /// Withdraws reads and unsent operations and clears the entered token.
    public func close() { lifecycle.close(); value = "" }
}
