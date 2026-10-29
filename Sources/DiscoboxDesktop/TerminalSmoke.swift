import AppKit
import GhosttyKit
import DiscoboxCore

/// Explicit offline integration check, launched with --terminal-smoke. Only a
/// synthetic PTY child is used; this path cannot use saved connection settings.
@MainActor enum TerminalSmoke {
    static func run(workspace: Workspace, store: TerminalStore) async {
        do {
            guard workspace.isDemo, let project = workspace.projectID,
                  let box = workspace.sandboxID, let exec = workspace.execID else { throw Failure("Demo selection missing") }
            let identity = TerminalIdentity(connection: workspace.connectionID, endpoint: "offline", project: project, box: box, exec: exec, demo: true)
            let session = store.session(identity)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.title = "Discobox offline terminal check"
            window.contentView = session.view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(session.view)
            do { try await wait { text(session.view).contains("Unicode: café 日本語") } }
            catch { throw Failure("Initial output: error=\(session.error ?? "none") text=\(text(session.view))") }
            print("SMOKE: initial output OK")
            guard let surface = session.view.surface else { throw Failure("No surface") }
            let size = ghostty_surface_size(surface)
            guard size.columns > 0, size.rows > 0 else { throw Failure("Invalid terminal dimensions") }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
            session.view.keyDown(with: event)
            try await wait { text(session.view).contains("> z") }; print("SMOKE: key OK")
            session.view.insertText("INPUT-é", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await wait { text(session.view).contains("zINPUT-é") }; print("SMOKE: text OK")
            // Verify bytes received by the raw fixture, not just event handling.
            for (flags, marker): (NSEvent.ModifierFlags, String) in [(.shift, "<ESC><RETURN>"), (.control, "<LF>")] {
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                session.view.keyDown(with: enter)
                do { try await wait { text(session.view).contains(marker) } }
                catch { throw Failure("Missing \(marker), received: \(text(session.view))") }
            }
            print("SMOKE: Shift-Enter and Ctrl-Enter bytes OK")
            window.setContentSize(NSSize(width: 1000, height: 600))
            try await wait { ghostty_surface_size(surface).columns > size.columns }; print("SMOKE: resize OK")
            let mountedSize = ghostty_surface_size(surface)
            let mountedFrame = session.view.frame
            window.contentView = NSView()
            session.view.setFrameSize(NSSize(width: 1, height: 1))
            try await Task.sleep(for: .milliseconds(150))
            let detachedSize = ghostty_surface_size(surface)
            guard mountedSize.columns == detachedSize.columns && mountedSize.rows == detachedSize.rows else { throw Failure("detached layout resized PTY") }
            session.view.frame = mountedFrame
            window.contentView = session.view
            try await wait { ghostty_surface_size(surface).columns == mountedSize.columns }
            print("SMOKE: detached transient geometry ignored")
            // These control bytes affect only the synthetic child, never a shell.
            "\u{1}".withCString { ghostty_surface_text(surface, $0, 1) }
            try await wait { text(session.view).contains("Alternate screen fixture") }; print("SMOKE: alternate OK")
            "\u{2}".withCString { ghostty_surface_text(surface, $0, 1) }
            try await wait { text(session.view).contains("zINPUT-é") }; print("SMOKE: text OK")
            let selectAll = "select_all"
            selectAll.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(selectAll.utf8.count)) }
            guard ghostty_surface_has_selection(surface) else { throw Failure("Selection unavailable") }
            guard store.session(identity) === session else { throw Failure("Session identity was not retained") }
            guard session.view.layer != nil else { throw Failure("Renderer layer missing") }
            guard let inventory = workspace.terminalInventory else { throw Failure("Missing live inventory") }
            let removedIdentity = TerminalIdentity(connection: identity.connection, endpoint: "offline", project: project, box: box, exec: "removed-fixture", demo: true)
            let otherIdentity = TerminalIdentity(connection: identity.connection, endpoint: "offline", project: project, box: "demo-api", exec: "other-fixture", demo: true)
            let removed = store.session(removedIdentity)
            let other = store.session(otherIdentity)
            guard removed.view.surface != nil, other.view.surface != nil else { throw Failure("Cleanup fixtures did not create surfaces") }
            store.retainExecs(inventory, connection: identity.connection)
            guard removed.view.surface == nil, other.view.surface != nil,
                  session.view.surface != nil, store.session(identity) === session else {
                throw Failure("Inventory cleanup removed a valid surface or kept an obsolete surface")
            }
            store.retainRunningBoxes(workspace.sandboxes, connection: identity.connection)
            guard other.view.surface == nil, session.view.surface != nil else { throw Failure("Stopped-box cleanup affected the live box") }
            print("SMOKE: obsolete surfaces freed; valid and other-box sessions preserved")
            "\u{3}".withCString { ghostty_surface_text(surface, $0, 1) }
            try await wait { ghostty_surface_process_exited(surface) }
            session.close()
            window.orderOut(nil)
            store.closeAll()
            print("TERMINAL_SMOKE_OK: PTY output, Unicode, keyboard input, text insertion, resize, alternate screen, selection, retained session identity, process exit, surface teardown")
            fflush(stdout)
            exit(0)
        } catch {
            print("TERMINAL_SMOKE_FAILED: \(error)")
            fflush(stdout)
            store.closeAll()
            exit(1)
        }
    }
    private static func text(_ view: GhosttyTerminalView) -> String {
        guard let surface = view.surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_SCREEN
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_SCREEN
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &result) else { return "" }
        defer { ghostty_surface_free_text(surface, &result) }
        return result.text.map { String(cString: $0) } ?? ""
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Timed out waiting for terminal state")
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
