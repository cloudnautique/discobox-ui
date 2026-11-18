#if DEBUG
import AppKit
import DiscoboxCore
@testable import DiscoboxUI

/// Exercises the production shell and sidebar in the fixture's workspace
/// window. Layout and responder ownership are testable with a locked display.
@MainActor enum SidebarLayoutSmoke {
    static func run(session: ConnectionSession, store: TerminalStore, commands: WorkspaceCommands) async throws {
        try await wait { commands.window?.contentView != nil && session.selection.selectedExec?.primary == true }
        let window = commands.window!
        let root = window.contentView!
        func identity(_ exec: String) -> TerminalIdentity {
            .init(connection: session.connectionState.connectionID, endpoint: session.connectionState.transportEndpoint,
                  project: session.connectionState.projectID!, box: session.selection.sandboxID!, exec: exec, demo: true)
        }
        let agentID = identity(session.selection.execID!)
        try await wait { store.existing(agentID)?.view.window === window }
        let agent = store.existing(agentID)!.view
        commands.perform(.newShell)
        try await wait { session.selection.selectedExec?.isShell == true }
        let shellID = identity(session.selection.execID!)
        try await wait { store.existing(shellID)?.view.window === window }
        let shell = store.existing(shellID)!.view
        func listFrame() -> NSRect? {
            guard let list = table(in: root), list.numberOfRows > 0, !list.isHiddenOrHasHiddenAncestor,
                  !list.visibleRect.isEmpty else { return nil }
            return list.convert(list.visibleRect, to: root)
        }
        func docked() -> Bool {
            guard let list = listFrame() else { return false }
            let left = agent.convert(agent.visibleRect, to: root), right = shell.convert(shell.visibleRect, to: root)
            return list.width > 190 && list.maxX <= left.minX && left.width > 250 &&
                left.maxX <= right.minX && right.width > 250 && right.maxX <= root.bounds.maxX
        }
        for width in [1320, 1000, 1320] {
            window.setContentSize(NSSize(width: width, height: 750))
            try await wait { abs(window.contentLayoutRect.width - CGFloat(width)) < 1 && docked() }
            guard window.makeFirstResponder(shell), window.firstResponder === shell, docked() else {
                throw DiscoboxError("Shell focus displaced the sidebar at width \(width)")
            }
        }
        commands.focusMode = true
        try await wait { listFrame() == nil }
        commands.focusMode = false
        try await wait { docked() }
        guard store.existing(shellID)?.view === shell && store.existing(agentID)?.view === agent else {
            throw DiscoboxError("Toggling the sidebar replaced a terminal")
        }
        print("SIDEBAR_LAYOUT_SMOKE_OK: docked agent list, agent and shell at 1000 and 1320 points, shell responder, explicit hide/show and retained terminals")
        fflush(stdout)
        exit(0)
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<160 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DiscoboxError("Sidebar layout check timed out at line \(line)")
    }
}
#endif
