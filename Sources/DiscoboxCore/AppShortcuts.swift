import Foundation

public enum AppShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case newBox, switchBox, previousTab, nextTab, previousPane, nextPane, help
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newBox: "New Box"
        case .switchBox: "Switch Box"
        case .previousTab: "Previous Tab"
        case .nextTab: "Next Tab"
        case .previousPane: "Previous Pane"
        case .nextPane: "Next Pane"
        case .help: "Workspace Help"
        }
    }
    public var defaultBinding: String {
        switch self {
        case .newBox: "cmd+n"
        case .switchBox: "cmd+k"
        case .previousTab: "cmd+shift+["
        case .nextTab: "cmd+shift+]"
        case .previousPane: "cmd+["
        case .nextPane: "cmd+]"
        case .help: "cmd+h"
        }
    }
}

public struct AppShortcut: Equatable, Sendable {
    public let key: String
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public init?(_ value: String) {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, key.count == 1,
              key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let mods = Array(parts.dropLast())
        guard mods.contains("cmd"), Set(mods).count == mods.count,
              mods.allSatisfy({ ["cmd", "shift", "option", "ctrl"].contains($0) }) else { return nil }
        // Braces are accepted as a readable alias for Shift-brackets.
        self.key = key == "{" ? "[" : key == "}" ? "]" : key
        shift = mods.contains("shift") || key == "{" || key == "}"
        option = mods.contains("option")
        control = mods.contains("ctrl")
    }
}

public struct AppShortcuts: Codable, Equatable, Sendable {
    private var values: [String: String] = [:]
    public init() {}
    public subscript(_ action: AppShortcutAction) -> String {
        get { values[action.rawValue] ?? action.defaultBinding }
        set { values[action.rawValue] = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
    public var validationError: String? {
        var seen: [AppShortcut] = []
        for action in AppShortcutAction.allCases {
            let value = self[action]
            if value.isEmpty { continue }
            guard let shortcut = AppShortcut(value) else { return "\(action.title): use cmd+key, optionally with shift, option, or ctrl." }
            if seen.contains(shortcut) { return "\(action.title) uses the same shortcut as another command." }
            // These are already owned by standard editing/window/app commands.
            if !shortcut.shift && !shortcut.option && !shortcut.control && ["a", "c", "v", "x", "z", "q", "w", ",", "r", "s"].contains(shortcut.key) {
                return "\(value) is reserved for an existing app or editing command."
            }
            seen.append(shortcut)
        }
        return nil
    }
}
