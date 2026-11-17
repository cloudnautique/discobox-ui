import Foundation

/// A decision on one approval request. Views describe the decision; Core owns
/// the action name and the wire payload.
public enum ApprovalAnswer: Sendable, Equatable {
    case deny
    /// API access and adoption consent carry no payload.
    case approve
    /// A replacement token entered by the person. No suggested command is run.
    case refresh(token: String)
    /// Scalar credential grants on servers without structured requests.
    case credential(request: JSONValue, secretID: String, duration: String, maximum: Double?)
    case trust(certificate: JSONValue, duration: String)
    /// A structured binding decision reviewed against `contextFingerprint`.
    case reviewedCredential(approval: JSONValue, contextFingerprint: JSONValue)

    public var action: String {
        switch self {
        case .deny: "deny"
        case .refresh: "refresh"
        case .approve, .credential, .trust, .reviewedCredential: "approve"
        }
    }

    public func payload() throws -> JSONValue {
        switch self {
        case .deny, .approve: return .object([:])
        case .refresh(let token):
            guard !token.isEmpty else { throw DiscoboxError("Enter a replacement token.") }
            return .object(["value": .string(token), "via": .string("entered")])
        case .credential(let request, let secretID, let duration, let maximum):
            return try LegacyCredentialDecision.payload(request: request, secretID: secretID, duration: duration, maximum: maximum)
        case .trust(let certificate, let duration):
            // A CA is pinned by its certificate; a leaf by its public key.
            let ca = certificate["isCA"] == .bool(true)
            let fingerprint = certificate[ca ? "sha256" : "spkiSha256"]
            guard !fingerprint.string.isEmpty else { throw DiscoboxError("Choose a certificate to trust.") }
            var fields = try ApprovalDuration.fields(duration, kind: "trust", maximum: nil)
            fields["pin"] = .object(["kind": .string(ca ? "ca" : "leaf-spki"), "sha256": fingerprint])
            return .object(fields)
        case .reviewedCredential(let approval, let fingerprint):
            guard !fingerprint.string.isEmpty else { throw DiscoboxError("Review the request again before applying it.") }
            return .object(["approval": approval, "contextFingerprint": fingerprint])
        }
    }
}

/// An audit row's identity, `trail/pool/record`.
public struct AuditRecordReference: Sendable, Equatable {
    public let pool: String
    public let record: String
    public init?(_ id: String) {
        let pieces = id.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count >= 3, !pieces[1].isEmpty, !pieces[2].isEmpty else { return nil }
        pool = String(pieces[1]); record = String(pieces[2])
    }
}

/// Typed requests for the Desktop. Each names the connection it was started
/// on (see `perform(on:_:)`) and its target explicitly, never the ambient
/// selection, so views neither build wire requests nor race a reconnect.
extension Workspace {
    public func tools(box: String, connection: UUID) async throws -> [JSONValue] {
        try await perform(on: connection) { .init(.tools, projectID: $0, sandboxID: box) }["tools"].array
    }

    /// Read-only: limits, holdings and bindings from the requesting box.
    public func approvalContext(for item: ApprovalItem, candidate: JSONValue?, connection: UUID) async throws -> JSONValue {
        try await perform(on: connection) { .init(.approvalContext, projectID: $0, requestID: item.id, payload: candidate) }
    }

    /// Validates the request is still pending, then answers it once. After
    /// validation `proceed` can still withdraw (a closed window); nothing is
    /// sent and nil is returned.
    @discardableResult
    public func answer(_ item: ApprovalItem, _ answer: ApprovalAnswer, connection: UUID, proceed: () -> Bool = { true },
                       onAccepted: (JSONValue) -> Void = { _ in }) async throws -> JSONValue? {
        let payload = try answer.payload()
        try await validateApproval(item, connection: connection)
        guard proceed() else { return nil }
        return try await answerWithReceipt(item, action: answer.action, payload: payload, onAccepted: onAccepted)
    }

    /// Stores a credential and returns its ID. A reply without one is
    /// ambiguous: the credential may exist, so it is never retried.
    public func createSecret(_ payload: JSONValue, connection: UUID) async throws -> String {
        let made = try await perform(on: connection) { .init(.createSecret, projectID: $0, payload: payload) }
        guard !made["id"].string.isEmpty else { throw DiscoboxError("Credential may have been stored. Check Settings → Credentials before retrying.") }
        return made["id"].string
    }

    public func deleteSecret(_ id: String, connection: UUID) async throws {
        _ = try await perform(on: connection) { .init(.deleteSecret, projectID: $0, secretID: id) }
    }

    public func updateSecretLimits(_ id: String, payload: JSONValue, connection: UUID) async throws -> JSONValue {
        try await perform(on: connection) { .init(.updateSecretLimits, projectID: $0, secretID: id, payload: payload) }
    }

    public func poolConfiguration(_ pool: String, connection: UUID) async throws -> JSONValue {
        try await perform(on: connection) { .init(.poolConfiguration, projectID: $0, poolID: pool) }
    }

    public func updatePoolProxy(_ pool: String, payload: JSONValue, connection: UUID) async throws -> JSONValue {
        try await perform(on: connection) { .init(.updatePoolProxy, projectID: $0, payload: payload, poolID: pool) }
    }

    /// A bounded preview of one recorded body (`part`: request, response or stream).
    public func auditBody(_ record: AuditRecordReference, part: String, box: String, connection: UUID) async throws -> JSONValue {
        try await perform(on: connection) { .init(.auditBody, projectID: $0, sandboxID: box, recordID: record.record, action: part, poolID: record.pool) }
    }

    public func saveAuditBody(_ record: AuditRecordReference, part: String, box: String, to destination: URL, connection: UUID) async throws -> JSONValue {
        try await perform(on: connection) { .init(.saveAuditBody, projectID: $0, sandboxID: box, recordID: record.record, action: part, localPath: destination.path, poolID: record.pool) }
    }
}
