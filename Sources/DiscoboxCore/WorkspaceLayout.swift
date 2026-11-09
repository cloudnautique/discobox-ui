import Foundation
import Observation

/// Client-side presentation only. Hiding, splitting and naming panes never
/// creates, stops or renames a server exec.
@MainActor @Observable public final class WorkspaceLayout {
    public private(set) var selected = "agent"
    public private(set) var lastCompanion: String?
    public private(set) var tools: [String] = []
    public private(set) var terminalIDs: [String] = []
    public private(set) var splitIDs: [String] = []
    public var shellSideBySide = false
    public var agentFocused = true
    public private(set) var names: [String: String] = [:]
    public var ids: [String] { ["agent"] + terminalIDs + tools }
    public var companionIDs: [String] { terminalIDs + tools }
    public var isSplit: Bool { selected != "agent" }
    public var visibleCompanions: [String] {
        guard isSplit else { return [] }
        return splitIDs.count == 2 && splitIDs.contains(selected) ? splitIDs : [selected]
    }
    public var shellsSplit: Bool { visibleCompanions.count == 2 }
    public init() {}

    public func open(_ id: String) {
        guard id == "agent" || terminalIDs.contains(id) || ["audit", "files"].contains(id) else { return }
        if ["audit", "files"].contains(id), !tools.contains(id) { tools.append(id) }
        selected = id
        agentFocused = id == "agent"
        if id != "agent" { lastCompanion = id }
    }
    public func hideCompanions() { open("agent") }
    @discardableResult public func restoreCompanions() -> Bool {
        guard let id = lastCompanion.flatMap({ companionIDs.contains($0) ? $0 : nil }) ?? companionIDs.first else { return false }
        open(id)
        return true
    }
    public func split(with id: String) {
        guard terminalIDs.contains(selected), terminalIDs.contains(id), selected != id else { return }
        splitIDs = [selected, id]
        open(id)
    }
    public func mergeShells() { splitIDs = [] }
    public func rename(_ id: String, to name: String) {
        guard terminalIDs.contains(id) else { return }
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        names[id] = value.isEmpty ? nil : value
    }
    public func close(_ id: String) {
        tools.removeAll { $0 == id }
        if selected == id { open(companionIDs.first(where: { $0 != id }) ?? "agent") }
        if lastCompanion == id { lastCompanion = companionIDs.first(where: { $0 != id }) }
    }
    public func reconcile(_ terminals: [String]) {
        let previous = companionIDs
        let previousTerminals = terminalIDs
        let survivingSplit = splitIDs.first { $0 != selected && terminals.contains($0) }
        var seen = Set<String>()
        terminalIDs = terminals.filter { $0.hasPrefix("exec:") && seen.insert($0).inserted }
        splitIDs = splitIDs.filter { terminalIDs.contains($0) }
        if splitIDs.count < 2 { splitIDs = [] }
        names = names.filter { terminalIDs.contains($0.key) }
        if selected != "agent", !companionIDs.contains(selected) {
            if selected.hasPrefix("exec:") {
                let index = previousTerminals.firstIndex(of: selected) ?? 0
                open(survivingSplit ?? (terminalIDs.isEmpty ? "agent" : terminalIDs[min(index, terminalIDs.count - 1)]))
            } else {
                let index = previous.firstIndex(of: selected) ?? 0
                open(companionIDs.isEmpty ? "agent" : companionIDs[min(index, companionIDs.count - 1)])
            }
        }
        if let lastCompanion, !companionIDs.contains(lastCompanion) { self.lastCompanion = companionIDs.first }
    }
    public func moveTab(_ delta: Int) {
        let tabs = companionIDs
        guard !tabs.isEmpty else { return }
        guard let index = tabs.firstIndex(of: selected) else {
            open(delta > 0 ? tabs[0] : tabs[tabs.count - 1]); return
        }
        open(tabs[(index + delta + tabs.count) % tabs.count])
    }
    public func movePane(_ delta: Int = 1) {
        guard isSplit else { return }
        let panes = ["agent"] + visibleCompanions
        let focused = agentFocused ? "agent" : selected
        let index = panes.firstIndex(of: focused) ?? 0
        let next = panes[(index + delta + panes.count) % panes.count]
        if next == "agent" { agentFocused = true }
        else { open(next) }
    }
}
