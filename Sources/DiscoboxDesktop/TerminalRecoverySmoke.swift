import AppKit
import GhosttyKit
import DiscoboxCore

/// Real PTYs and native selection with synthetic children only. No live server,
/// saved connections, system clipboard, or backend mutations are involved.
@MainActor enum TerminalRecoverySmoke {
    static func run() async {
        do {
            try await statusChannel()
            try await disconnectedSelection()
            try await preservedOutput()
            print("TERMINAL_RECOVERY_SMOKE_OK: event-driven state, ordinary selection/copy/scroll after TUI exit, typing cannot close saved output, bounded output survives reconnect/cooldown/failed attempts and cleanup")
            fflush(stdout); exit(0)
        } catch {
            print("TERMINAL_RECOVERY_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1)
        }
    }

    private static func statusChannel() async throws {
        let status = try TerminalAttachStatus()
        defer { status.close() }
        var states: [String] = []
        status.receive = { state, _ in states.append(state) }
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: status.path))
        defer { try? writer.close() }
        for state in ["connecting", "connected", "reconnecting", "reconnected"] {
            try writer.write(contentsOf: Data("{\"state\":\"\(state)\"}\n".utf8))
            try await wait { states.last == state }
        }
        guard states.count == 4 else { throw DiscoboxError("State channel lost or duplicated an event") }
        let path = status.path
        status.close()
        guard !FileManager.default.fileExists(atPath: path) else { throw DiscoboxError("Status FIFO was not removed") }
    }

    private static func disconnectedSelection() async throws {
        let view = GhosttyTerminalView(frame: .init(x: 0, y: 0, width: 850, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let script = "/usr/bin/printf '\\033[?1000h\\033[?1006hCOPY_PROBE'; /bin/sleep 0.6"
        if let error = view.start(command: "/bin/sh -c " + TerminalSession.quote(script)) { throw DiscoboxError(error) }
        defer { view.close(); window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        try await wait { view.surface.map(ghostty_surface_process_exited) == true && view.readOnly }
        guard let surface = view.surface, !ghostty_surface_mouse_captured(surface) else { throw DiscoboxError("Exited TUI retained mouse capture") }
        let before = view.outputText()
        guard before.contains("COPY_PROBE"), !before.contains("Press any key to close") else { throw DiscoboxError("Disconnect modified the remote screen") }
        let lines = before.components(separatedBy: "\n")
        guard let row = lines.firstIndex(where: { $0.contains("COPY_PROBE") }) else { throw DiscoboxError("Missing copied text") }
        let size = ghostty_surface_size(surface), scale = window.backingScaleFactor
        let y = (Double(row) + 0.5) * Double(size.cell_height_px) / scale
        let mods = ghostty_input_mods_e(rawValue: 0)
        ghostty_surface_mouse_pos(surface, Double(size.cell_width_px) * 0.5 / scale, y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pos(surface, Double(size.cell_width_px) * 9.5 / scale, y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        guard ghostty_surface_has_selection(surface) else { throw DiscoboxError("Ordinary dragging cannot select disconnected output") }
        let copyItem = NSMenuItem(title: "Copy", action: #selector(GhosttyTerminalView.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(GhosttyTerminalView.paste(_:)), keyEquivalent: "v")
        let selectItem = NSMenuItem(title: "Select All", action: #selector(GhosttyTerminalView.selectAll(_:)), keyEquivalent: "a")
        guard view.responds(to: copyItem.action), view.responds(to: pasteItem.action),
              view.validateUserInterfaceItem(copyItem), view.validateUserInterfaceItem(selectItem),
              !view.validateUserInterfaceItem(pasteItem) else {
            throw DiscoboxError("Disconnected terminal must expose native Copy/Select All and disable Paste")
        }
        view.paste(nil) // Must not consult the system clipboard or send input.
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        view.copyOutput(to: clipboard)
        guard clipboard.string(forType: .string)?.contains("COPY_PROBE") == true else { throw DiscoboxError("Offline copy needs a live backend") }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
        view.keyDown(with: event)
        guard view.outputText() == before, ghostty_surface_has_selection(surface) else { throw DiscoboxError("Typing changed read-only output or its selection") }
    }

    private static func preservedOutput() async throws {
        let workspace = Workspace(), store = TerminalStore()
        defer { store.closeAll(); workspace.disconnect() }
        await workspace.connect(client: DemoClient(), label: "Offline recovery", demo: true)
        await workspace.selectBox("demo-ui")
        guard let inventory = workspace.terminalInventory else { throw DiscoboxError("Missing terminal inventory") }
        let identity = TerminalIdentity(connection: workspace.connectionID, endpoint: "offline", project: inventory.project, box: inventory.box, exec: "agent-1", demo: true)
        let old = store.session(identity)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = old.view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await wait { old.view.outputText().contains("Unicode: café 日本語") }
        old.view.processEnded()
        store.recoverInterrupted(inventory, connection: workspace.connectionID)
        let replacement = store.session(identity)
        guard replacement !== old, old.view.surface == nil,
              replacement.previousOutput?.contains("Unicode: café 日本語") == true else { throw DiscoboxError("Reconnect discarded useful text") }
        replacement.ended = true
        store.recoverInterrupted(inventory, connection: workspace.connectionID)
        guard store.session(identity) === replacement else { throw DiscoboxError("Recovery ignored its cooldown") }
        store.reconnect(identity)
        let retry = store.session(identity)
        guard retry.previousOutput?.contains("Unicode: café 日本語") == true else { throw DiscoboxError("An empty reconnect attempt overwrote saved output") }
        store.closeBox(identity.box, connection: identity.connection)
        guard store.session(identity).previousOutput == nil else { throw DiscoboxError("Closing the box leaked retained output") }
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 { if predicate() { return }; try await Task.sleep(for: .milliseconds(40)) }
        throw DiscoboxError("Terminal recovery check timed out")
    }
}
