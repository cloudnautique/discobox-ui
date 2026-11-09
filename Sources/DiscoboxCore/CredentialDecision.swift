import Foundation

/// Modern binding approvals are distinct from the older grant API. Omission is
/// not consent: every requested part must have an explicit answer.
public struct CredentialPartDecision: Sendable, Equatable {
    public var decision = ""
    public var scope = "routes"
    public var duration = ApprovalDuration.automatic
    public var mode = "replace"
    public var delivery = "sentinel"
    public init() {}
    public func fields(use: Bool, secret: JSONValue) throws -> JSONValue {
        guard ["approve", "deny"].contains(decision) else { throw DiscoboxError("Choose Allow or Deny for each requested part.") }
        if decision == "deny" { return .object(["decision": .string("deny")]) }
        guard ["routes", "hosts", "anywhere"].contains(scope) else { throw DiscoboxError("Choose a grant scope.") }
        let maximum = secret["maxBindingTTLSeconds"].number
        let durationFields = try ApprovalDuration.fields(duration, kind: "credential", maximum: maximum)
        var out: [String: JSONValue] = ["decision": .string(decision), "scope": .string(scope)]
        if let seconds = durationFields["grantTTLSeconds"] { out["ttlSeconds"] = seconds }
        if use {
            guard ["add", "replace"].contains(mode) else { throw DiscoboxError("Choose Add or Replace.") }
            out["as"] = .string(mode)
            if delivery != "sentinel" {
                guard ["env", "file"].contains(delivery), secret["allowRaw"] == .bool(true), mode != "add" else {
                    throw DiscoboxError("Raw delivery requires a credential that allows it and a replacement grant.")
                }
                out["raw"] = .string(delivery)
            }
        }
        return .object(out)
    }
}

public enum CredentialDecision {
    public static func holder(request: JSONValue, held: [JSONValue]) -> JSONValue {
        held.first { $0["envVar"] == request["envName"] && $0["use"] == .bool(true) && $0["adds"] != .bool(true) && $0["notApplied"].string.isEmpty } ?? .null
    }
    public static func payload(request: JSONValue, secret: JSONValue, held: [JSONValue], use: CredentialPartDecision, delegate: CredentialPartDecision) throws -> JSONValue {
        let approves = request["use"] != .null && use.decision == "approve" || request["delegate"] != .null && delegate.decision == "approve"
        var out: [String: JSONValue] = [:]
        if approves {
            guard !secret["id"].string.isEmpty else { throw DiscoboxError("Choose a credential explicitly.") }
            out["secretId"] = secret["id"]
            let holder = holder(request: request, held: held)
            if !holder["secretId"].string.isEmpty && holder["secretId"] != secret["id"] {
                if holder["from"].string == "sandbox" && holder["fromId"] == request["sandboxId"] || use.decision == "approve" && use.mode == "add" {
                    throw DiscoboxError("This variable already holds another credential. An addition must use that credential; a box-level binding pins the choice.")
                }
            }
        }
        if request["use"] != .null { out["use"] = try use.fields(use: true, secret: secret) }
        if request["delegate"] != .null { out["delegate"] = try delegate.fields(use: false, secret: secret) }
        return .object(out)
    }
}
