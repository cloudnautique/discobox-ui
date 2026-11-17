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
