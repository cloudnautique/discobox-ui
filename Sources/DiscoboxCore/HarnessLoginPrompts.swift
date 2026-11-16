import Foundation

/// Remembers presentation, not consent. Saving still requires a fresh review
/// and an explicit action. Only opaque identities are persisted here.
public enum HarnessLoginPrompts {
    public static func key(preview: JSONValue, computer: String, project: String, harness: String, box: String) -> String? {
        guard preview["state"].string == "pending", preview["harnessConfigId"].string == harness,
              HarnessCapture.canSave(preview), !preview["credentials"].array.isEmpty,
              !computer.isEmpty, !project.isEmpty, !harness.isEmpty, !box.isEmpty else { return nil }
        let identity = [computer, project, harness, box, preview["candidateId"].string]
        return (try? JSONEncoder().encode(identity)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func contains(_ key: String, in stored: String) -> Bool {
        decode(stored).contains(key)
    }

    public static func recording(_ key: String, in stored: String) -> String {
        let keys = (decode(stored).filter { $0 != key } + [key]).suffix(256)
        return (try? JSONEncoder().encode(Array(keys))).flatMap { String(data: $0, encoding: .utf8) } ?? stored
    }

    private static func decode(_ stored: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? []
    }
}
