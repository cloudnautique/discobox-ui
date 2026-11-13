import Foundation

public enum HarnessSelection {
    /// Keep an explicit choice when available; otherwise prefer the project's
    /// default over catalog order. An unavailable default cannot be launched.
    public static func preferred(in harnesses: [Harness], defaultID: String?, explicitID: String? = nil) -> String {
        let available = harnesses.filter(\.configured)
        if let explicitID, available.contains(where: { $0.id == explicitID }) { return explicitID }
        if let defaultID, available.contains(where: { $0.id == defaultID }) { return defaultID }
        return available.first?.id ?? ""
    }
}
