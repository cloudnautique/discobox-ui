import Foundation

public enum CredentialLimits {
    public static func isLegacy(_ secret: JSONValue) -> Bool {
        secret["maxGrantTTLSeconds"].number != nil && secret["maxBindingTTLSeconds"] == .null
    }
    public static func maximum(_ secret: JSONValue) -> Double? {
        secret["maxBindingTTLSeconds"].number ?? secret["maxGrantTTLSeconds"].number
    }
    public static func payload(secret: JSONValue, seconds: String, host: String) throws -> JSONValue {
        guard maximum(secret) != nil, let seconds = Int(seconds), seconds >= 0 else { throw DiscoboxError("Enter a nonnegative maximum lifetime in seconds. Zero permits access without expiry.") }
        var limits: [String: JSONValue] = [isLegacy(secret) ? "maxGrantTTLSeconds" : "maxBindingTTLSeconds": .number(Double(seconds))]
        if isLegacy(secret) { limits["host"] = .string(host.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .object(["expectedSecret": secret, "limits": .object(limits)])
    }
}
