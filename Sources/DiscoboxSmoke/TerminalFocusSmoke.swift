#if DEBUG
import AppKit
import DiscoboxCore
@testable import DiscoboxUI

@MainActor enum TerminalFocusSmoke {
    static func run(connections: Connections, session: ConnectionSession, store: TerminalStore, commands: WorkspaceCommands) async throws {
        try await wait { commands.window?.contentView != nil && session.selection.execID != nil }
        let window = commands.window!, root = window.contentView!
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait { window.isKeyWindow }
        let identity = TerminalIdentity(connection: session.connectionState.connectionID, endpoint: session.connectionState.transportEndpoint,
                                        project: session.connectionState.projectID!, box: session.selection.sandboxID!, exec: session.selection.execID!, demo: true)
        try await wait { store.existing(identity)?.view.window === window }
        let agent = store.existing(identity)!.view
        guard let sidebar = descendants(root).compactMap({ $0 as? NSTableView }).first,
              let search = descendants(root).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Find a box" })
        else { throw DiscoboxError("Missing sidebar controls") }

        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.postEvent(event, atStart: false)
            }
        }

        // Reproduce AppKit attaching a zero-size container behind a creation sheet.
        let late = TerminalContainerView(frame: .zero), surface = GhosttyTerminalView(frame: .zero)
        let layout = WorkspaceTabs()
        commands.requestAgentFocus(in: layout)
        late.setFocusRequest(true, handoff: commands.agentFocusRequest)
        window.makeFirstResponder(sidebar)
        root.addSubview(late)
        defer { late.removeFromSuperview() }
        late.bind(surface)
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        late.frame.size = NSSize(width: 220, height: 80)
        late.needsLayout = true
        late.layoutSubtreeIfNeeded()
        try await wait { surface.superview === late && window.attachedSheet === sheet }
        try await Task.sleep(for: .milliseconds(100))
        guard window.firstResponder !== surface else { throw DiscoboxError("Terminal took focus behind a sheet") }
        window.endSheet(sheet)
        try await wait { window.firstResponder === surface }
        window.makeFirstResponder(sidebar)
        late.needsLayout = true
        late.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        guard window.firstResponder === sidebar else { throw DiscoboxError("Layout replayed a consumed focus request") }

        late.frame.size = .zero
        commands.requestAgentFocus(in: layout)
        let pending = commands.agentFocusRequest!
        late.setFocusRequest(true, handoff: pending)
        click(search.convert(NSPoint(x: search.bounds.midX, y: search.bounds.midY), to: nil))
        try await wait { search.currentEditor() != nil && !pending.pending }
        late.frame.size = NSSize(width: 220, height: 80)
        late.needsLayout = true
        late.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        guard window.firstResponder === search.currentEditor() else { throw DiscoboxError("Late terminal stole search focus") }
        late.removeFromSuperview()

        // Click the non-button area of the actual Agent header, while its layout
        // already lists Agent as selected, then deliver a key through AppKit.
        let pane = agent.convert(agent.bounds, to: nil)
        click(NSPoint(x: pane.midX, y: pane.maxY + DiscoboxAppearance.terminalInset + 18))
        try await wait { window.firstResponder === agent }
        if agent.surface != nil {
            try await wait { agent.outputText().contains("Unicode: café 日本語") }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                             isARepeat: false, keyCode: 6)!
                NSApp.postEvent(event, atStart: false)
            }
            try await wait { agent.outputText().contains("> z") }
            print("TERMINAL_FOCUS_TYPED_OK")
        }
        // Use the workspace's real New Box sheet and offline creation path.
        // The box may finish mounting before SwiftUI restores the parent window.
        window.makeFirstResponder(sidebar)
        commands.newBox()
        try await wait { window.attachedSheet != nil }
        let created = try await connections.createBox(on: session.id, harness: "demo-harness", repository: "")
        let createdID = TerminalIdentity(connection: identity.connection, endpoint: identity.endpoint, project: identity.project,
                                         box: created.id, exec: identity.exec, demo: true)
        try await wait { store.existing(createdID)?.view.window === window }
        commands.showCreateBox = false
        let createdAgent = store.existing(createdID)!.view
        try await wait { window.attachedSheet == nil && window.firstResponder === createdAgent }

        commands.perform(.newShell)
        try await wait { window.firstResponder is GhosttyTerminalView && window.firstResponder !== createdAgent }
        let shell = window.firstResponder as! GhosttyTerminalView
        let secondLate = TerminalContainerView(frame: .zero)
        let secondSurface = GhosttyTerminalView(frame: .zero)
        commands.requestAgentFocus(in: layout)
        let displaced = commands.agentFocusRequest!
        secondLate.setFocusRequest(true, handoff: displaced)
        root.addSubview(secondLate)
        defer { secondLate.removeFromSuperview() }
        secondLate.bind(secondSurface)
        click(shell.convert(NSPoint(x: shell.bounds.midX, y: shell.bounds.midY), to: nil))
        try await wait { !displaced.pending }
        secondLate.frame.size = NSSize(width: 220, height: 80)
        secondLate.needsLayout = true
        secondLate.layoutSubtreeIfNeeded()
        try await wait { secondSurface.superview === secondLate }
        try await Task.sleep(for: .milliseconds(100))
        guard window.firstResponder === shell else { throw DiscoboxError("Delayed focus displaced the shell") }
        print("TERMINAL_FOCUS_SMOKE_OK")
        fflush(stdout)
        exit(0)
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<160 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DiscoboxError("Terminal focus check timed out at line \(line)")
    }
}
#endif
