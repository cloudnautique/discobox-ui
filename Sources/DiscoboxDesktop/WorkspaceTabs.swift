import SwiftUI

/// One tab selection and arrangement per box, retained while switching boxes.
@MainActor @Observable final class WorkspaceTabs {
    var selected = "agent"
    var tools: [String] = []
    var terminalIDs: [String] = []
    var keepAgent = true
    var sideBySide = true
    var agentFocused = true
    var ids: [String] { ["agent"] + terminalIDs + tools }
    var isSplit: Bool { keepAgent && selected != "agent" }

    func open(_ id: String) {
        if ["audit", "services", "files"].contains(id), !tools.contains(id) { tools.append(id) }
        selected = id
        agentFocused = id == "agent"
    }
    func close(_ id: String) {
        tools.removeAll { $0 == id }
        if selected == id { open("agent") }
    }
    func reconcile(_ terminals: [String]) {
        terminalIDs = terminals
        if !ids.contains(selected) { open("agent") }
    }
    func moveTab(_ delta: Int) {
        let tabs = keepAgent ? ids.filter { $0 != "agent" } : ids
        guard !tabs.isEmpty else { return }
        guard let index = tabs.firstIndex(of: selected) else {
            open(delta > 0 ? tabs[0] : tabs[tabs.count - 1]); return
        }
        open(tabs[(index + delta + tabs.count) % tabs.count])
    }
    func movePane() {
        guard isSplit else { return }
        agentFocused.toggle()
    }
}
