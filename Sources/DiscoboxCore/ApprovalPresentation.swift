import Foundation

/// Presentation adapters never translate one generation's approval into another
/// generation's grant. Unknown or malformed binding requests fail closed.
public enum ApprovalPresentation: Sendable, Equatable {
    case legacyCredential, bindingCredential, certificate, consent, unsupported
}

public extension ApprovalItem {
    var presentation: ApprovalPresentation {
        guard supported else { return .unsupported }
        if kind == "trust" { return .certificate }
        guard kind == "credential" else { return .consent }
        if case .object(let fields) = request {
            if fields.keys.contains("use") || fields.keys.contains("delegate") {
                let parts = [fields["use"], fields["delegate"]].compactMap { $0 }.filter { $0 != .null }
                guard !parts.isEmpty, parts.allSatisfy({ if case .object = $0 { return true }; return false }) else { return .unsupported }
                return .bindingCredential
            }
            return .legacyCredential
        }
        return .unsupported
    }
}

public enum TokenCredentialPayload {
    public static func current(name: String, value: String, routes: [JSONValue]) throws -> JSONValue {
        try validate(name: name, value: value)
        return .object(["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "type": .string("token"),
                        "value": .object(["token": .string(value)]), "routes": .array(routes), "maxBindingTTLSeconds": .number(3600)])
    }
    public static func legacy(name: String, value: String, host: String, maximum: Double) throws -> JSONValue {
        try validate(name: name, value: value)
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, host.utf8.count <= 253, !host.contains("\0") else { throw DiscoboxError("Enter an allowed destination host for this credential.") }
        guard maximum.isFinite, maximum >= 0, maximum.rounded() == maximum else { throw DiscoboxError("Choose a valid credential lifetime.") }
        return .object(["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "type": .string("token"),
                        "value": .object(["token": .string(value)]), "host": .string(host), "maxGrantTTLSeconds": .number(maximum)])
    }
    private static func validate(name: String, value: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { throw DiscoboxError("Enter a credential name of at most 200 characters.") }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 65536, !value.contains("\0") else { throw DiscoboxError("Enter a token of at most 64 KiB.") }
    }
}

public enum LegacyCredentialDecision {
    /// Preserve the complete server policy. This adapter cannot edit a shared
    /// secret, create an auto-approval rule, or synthesize a binding decision.
    public static func payload(request: JSONValue, secretID: String, duration: String, maximum: Double?) throws -> JSONValue {
        var fields = try ApprovalDuration.fields(duration, kind: "credential", maximum: maximum)
        if !secretID.isEmpty { fields["secretId"] = .string(secretID) }
        if request["policy"] != .null { fields["policy"] = request["policy"] }
        return .object(fields)
    }
}
