import Foundation

public enum CredentialLimits {
    public static func isLegacy(_ secret: JSONValue) -> Bool {
        secret["maxGrantTTLSeconds"].number != nil && secret["maxBindingTTLSeconds"] == .null
    }
    public static func maximum(_ secret: JSONValue) -> Double? {
        secret["maxBindingTTLSeconds"].number ?? secret["maxGrantTTLSeconds"].number
    }
    public static func lifetimeSeconds(_ text: String) throws -> Int {
        guard let seconds = Int(text), seconds >= 0, Int(exactly: Double(seconds)) == seconds else {
            throw DiscoboxError("Enter a nonnegative maximum lifetime in seconds. Zero permits access without expiry.")
        }
        return seconds
    }
    public static func payload(secret: JSONValue, seconds: String, host: String, routes: [JSONValue]? = nil) throws -> JSONValue {
        guard maximum(secret) != nil else { throw DiscoboxError("This credential does not report editable limits.") }
        let seconds = try lifetimeSeconds(seconds)
        var limits: [String: JSONValue] = [isLegacy(secret) ? "maxGrantTTLSeconds" : "maxBindingTTLSeconds": .number(Double(seconds))]
        if isLegacy(secret) { limits["host"] = .string(host.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let routes {
            guard !isLegacy(secret) else { throw DiscoboxError("This server uses a host restriction for this credential.") }
            limits["routes"] = .array(routes)
            if Double(seconds) == maximum(secret) { limits.removeValue(forKey: "maxBindingTTLSeconds") }
        }
        return .object(["expectedSecret": secret, "limits": .object(limits)])
    }
}
