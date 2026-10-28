import Foundation

/// Tag selectors match the backend: a bare key means presence, key=value is exact.
public enum BoxOrganization {
    public static func matches(tags: [String: String], selectors: Set<String>, matchAny: Bool) -> Bool {
        guard !selectors.isEmpty else { return true }
        let matches = selectors.map { selector in
            let parts = selector.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            return parts.count == 1 ? tags[key] != nil : tags[key] == String(parts[1])
        }
        return matchAny ? matches.contains(true) : matches.allSatisfy { $0 }
    }
    public static func group(_ box: Sandbox, by mode: String, tagKey: String) -> String {
        switch mode {
        case "harness": return box.harnessName ?? box.config.name ?? "Unknown harness"
        case "state": return box.status
        case "tag": return box.meta?.tags?[tagKey].map { $0.isEmpty ? "Tagged: \(tagKey)" : $0 } ?? "Untagged"
        default: return box.repository ?? "No repository"
        }
    }
}
