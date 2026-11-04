import Foundation

/// An untouched credential approval leaves lifetime selection to the server,
/// which fits the requested/default duration to the secret's current limit.
/// Zero is an explicit non-expiring grant, never an automatic/default value.
public enum ApprovalDuration {
    public static let automatic = "automatic"

    public static func fields(_ value: String, kind: String, maximum: Double? = nil) throws -> [String: JSONValue] {
        if value == automatic {
            guard kind == "credential" else { throw DiscoboxError("Choose a duration for this approval.") }
            return [:]
        }
        guard let seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), seconds >= 0 else {
            throw DiscoboxError("Enter a valid duration in seconds, or choose Automatic.")
        }
        if kind == "trust" {
            guard seconds > 0 && seconds <= 2_592_000 else { throw DiscoboxError("Trust must expire within 30 days.") }
        } else if let maximum, maximum.isFinite, maximum > 0, seconds == 0 || Double(seconds) > maximum {
            throw DiscoboxError("This credential allows grants of at most \(label(maximum)). Choose Automatic or a shorter duration.")
        }
        return ["grantTTLSeconds": .number(Double(seconds))]
    }

    public static func label(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide))
    }

    /// Secret selection follows IDs and the server's well-known credential
    /// binding. Names and hosts alone cannot identify the answering credential.
    public static func selectedSecret(id: String, request: JSONValue, secrets: [JSONValue]) -> JSONValue {
        if !id.isEmpty { return secrets.first { $0["id"].string == id } ?? .null }
        let wellKnownID = request["wellKnownId"].string
        guard !wellKnownID.isEmpty else { return .null }
        let matches = secrets.filter { $0["wellKnownId"].string == wellKnownID }
        return matches.count == 1 ? matches[0] : .null
    }
}
