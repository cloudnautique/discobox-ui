import Foundation

public enum HarnessCapture {
    public static func canSave(_ preview: JSONValue) -> Bool {
        !preview["candidateId"].string.isEmpty &&
        (preview["state"].string == "saved-handoff-pending" || preview["state"].string == "pending" &&
         (!preview["files"].array.isEmpty || !preview["credentials"].array.isEmpty))
    }
    public static func accepts(_ preview: JSONValue, harnessID: String) -> Bool {
        let owner = preview["harnessConfigId"].string
        if owner == harnessID { return true }
        return owner.isEmpty && ["unsupported", "initializing", "unavailable"].contains(preview["state"].string) &&
            preview["candidateId"].string.isEmpty && preview["files"].array.isEmpty && preview["credentials"].array.isEmpty
    }
    public static func explanation(_ preview: JSONValue) -> String? {
        switch preview["state"].string {
        case "unsupported": return "This harness does not support saving login or settings from a box. Its local changes remain in the box."
        case "initializing": return "The harness is preparing its saved-settings baseline. Check again shortly."
        case "unavailable": return "The box cannot report its harness changes right now. Local changes have not been saved or discarded."
        case "saved-handoff-pending": return "The shared login and settings are saved. The source box still needs its update; you do not need to sign in again."
        case "pending" where !canSave(preview): return "These changes already match the shared harness settings. There is nothing new to save."
        case "clean", "none", "saved", "discarded": return "There are no changes to share. Sign in or edit settings inside this box, then check again."
        default: return nil
        }
    }
}

/// Only a non-secret local preference. An endpoint, project and exact harness
/// identify independent defaults, including separate-account variants.
public enum HarnessLaunchDefaults {
    public static func key(computer: String, project: String, harness: String) -> String {
        let data = try? JSONEncoder().encode([computer, project, harness])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    public static func enabled(_ stored: String, key: String) -> Bool {
        (try? JSONDecoder().decode([String: Bool].self, from: Data(stored.utf8)))?[key] == true
    }
    public static func setting(_ stored: String, key: String, enabled: Bool) -> String {
        var values = (try? JSONDecoder().decode([String: Bool].self, from: Data(stored.utf8))) ?? [:]
        values[key] = enabled ? true : nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? stored
    }
}
