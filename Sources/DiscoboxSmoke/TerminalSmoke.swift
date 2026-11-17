#if DEBUG
@testable import DiscoboxUI
import AppKit
import SwiftUI
import GhosttyKit
import DiscoboxCore

/// Explicit offline integration check, launched with --terminal-smoke. Only a
/// synthetic PTY child is used; this path cannot use saved connection settings.
@MainActor enum TerminalSmoke {
    static func run(workspace: ConnectionSession, store: TerminalStore) async {
        let bounded = TerminalStore(hiddenSessionLimit: 1)
        do {
            guard workspace.connectionState.isDemo, let project = workspace.connectionState.projectID,
                  let box = workspace.selection.sandboxID, let exec = workspace.selection.execID else { throw Failure("Demo selection missing") }
            let identity = TerminalIdentity(connection: workspace.connectionState.connectionID, endpoint: "offline", project: project, box: box, exec: exec, demo: true)
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
            try await checkArrows(session.view, window: window, application: false)
            session.view.sendLiteral("\u{5}")
            try await wait { text(session.view).contains("Extended keyboard protocol enabled") }
            try await checkArrows(session.view, window: window, application: false)
            session.view.sendLiteral("\u{6}")
            try await wait { text(session.view).contains("Extended keyboard protocol disabled") }
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
            // Control-A must reach the fixture as byte 1, then arrows must
            // remain navigation events. This child is synthetic, never a shell.
            let controlA = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1}", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            session.view.keyDown(with: controlA)
            try await wait { text(session.view).contains("Alternate screen fixture") }; print("SMOKE: alternate OK")
            // Full-screen TUIs can enable application cursor mode. Test both
            // encodings, including navigation after a literal Control-A.
            session.view.sendLiteral("\u{4}")
            try await wait { text(session.view).contains("Application cursor keys enabled") }
            try await checkArrows(session.view, window: window, application: true)
            "\u{2}".withCString { ghostty_surface_text(surface, $0, 1) }
            try await wait { text(session.view).contains("zINPUT-é") }; print("SMOKE: text OK")
            // System Command-Control chords and read-only terminals leave key
            // equivalents to AppKit; neither sends anything to the fixture.
            window.makeFirstResponder(session.view)
            func equivalent(_ flags: NSEvent.ModifierFlags, _ key: String) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 3)!
            }
            guard !session.view.performKeyEquivalent(with: equivalent([.control, .command], "f")) else { throw Failure("terminal claimed Control-Command-F") }
            session.view.readOnly = true
            let claimedWhileReadOnly = session.view.performKeyEquivalent(with: equivalent(.control, "f"))
            session.view.readOnly = false
            guard !claimedWhileReadOnly else { throw Failure("read-only terminal claimed a Control chord") }
            print("SMOKE: system Control-Command chords pass through")
            let selectAll = "select_all"
            selectAll.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(selectAll.utf8.count)) }
            guard ghostty_surface_has_selection(surface) else { throw Failure("Selection unavailable") }
            guard store.session(identity) === session else { throw Failure("Session identity was not retained") }
            guard session.view.layer != nil else { throw Failure("Renderer layer missing") }
            guard let inventory = workspace.selection.terminalInventory else { throw Failure("Missing live inventory") }
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
            store.retainRunningBoxes(workspace.inventory.sandboxes, connection: identity.connection)
            guard other.view.surface == nil, session.view.surface != nil else { throw Failure("Stopped-box cleanup affected the live box") }
            print("SMOKE: obsolete surfaces freed; valid and other-box sessions preserved")
            // Evaluating a terminal view must not start a child; its task does.
            func fixture(_ exec: String) -> TerminalIdentity { TerminalIdentity(connection: identity.connection, endpoint: "offline", project: project, box: box, exec: exec, demo: true) }
            let shownIdentity = fixture("shown-fixture"), olderIdentity = fixture("older-fixture"), newerIdentity = fixture("newer-fixture")
            let host = NSHostingView(rootView: LiveTerminal(identity: shownIdentity).environment(bounded).environment(ServiceForwards()).environment(workspace))
            let shownWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            shownWindow.contentView = host
            shownWindow.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            guard bounded.existing(shownIdentity) == nil else { throw Failure("Evaluating the terminal view created a session") }
            do { try await wait { bounded.existing(shownIdentity)?.view.window === shownWindow } }
            catch { throw Failure("The terminal view's task did not create and mount its session") }
            let shown = bounded.existing(shownIdentity)!
            print("SMOKE: session created by the view task, not by body")
            // Over the hidden limit, the least recently used hidden session is
            // released; the mounted one is kept even though it is older.
            let older = bounded.session(olderIdentity)
            let newer = bounded.session(newerIdentity)
            bounded.releaseHiddenSessions()
            guard bounded.existing(shownIdentity) === shown, shown.view.surface != nil,
                  bounded.existing(olderIdentity) == nil, older.view.surface == nil,
                  bounded.existing(newerIdentity) === newer, newer.view.surface != nil else {
                throw Failure("Eviction released a shown session or kept the least recently used hidden one")
            }
            let returned = bounded.session(olderIdentity)
            guard returned !== older, returned.view.surface != nil else { throw Failure("A released terminal did not reattach on return") }
            // Unmount first so the view does not start a replacement.
            shownWindow.contentView = NSView()
            shownWindow.orderOut(nil)
            bounded.closeAll()
            print("SMOKE: hidden sessions bounded; shown session kept; released session reattaches")
            // Exit is reported by Ghostty's callbacks, even while hidden.
            window.contentView = NSView()
            "\u{3}".withCString { ghostty_surface_text(surface, $0, 1) }
            do { try await wait { ghostty_surface_process_exited(surface) && session.ended && session.view.readOnly } }
            catch { throw Failure("Child exit did not end the hidden session: exited=\(ghostty_surface_process_exited(surface)) ended=\(session.ended) readOnly=\(session.view.readOnly)") }
            session.close()
            window.orderOut(nil)
            store.closeAll()
            print("TERMINAL_SMOKE_OK: PTY output, Unicode, keyboard input, text insertion, navigation in legacy/application/extended modes, Control-A, resize, alternate screen, selection, retained session identity, view-task session creation, hidden-session bound, callback-driven process exit, surface teardown")
            fflush(stdout)
            exit(0)
        } catch {
            print("TERMINAL_SMOKE_FAILED: \(error)")
            fflush(stdout)
            bounded.closeAll()
            store.closeAll()
            exit(1)
        }
    }
    private static func checkArrows(_ view: GhosttyTerminalView, window: NSWindow, application: Bool) async throws {
        let arrows: [(UInt16, String, String)] = [(123, "\u{F702}", "D"), (124, "\u{F703}", "C"), (125, "\u{F701}", "B"), (126, "\u{F700}", "A")]
        for (flags, prefix): (NSEvent.ModifierFlags, String) in [([], application ? "O" : "["), (.shift, "[1;2"), (.control, "[1;5")] {
            for (code, characters, suffix) in arrows {
                let marker = "<ESC>" + prefix + suffix
                let count = text(view).components(separatedBy: marker).count
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                    if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
                }
                do { try await wait { text(view).components(separatedBy: marker).count > count } }
                catch { throw Failure("Missing arrow bytes \(marker), received: \(text(view))") }
                guard !text(view).unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { throw Failure("AppKit function-key character leaked into terminal") }
            }
        }
        print("SMOKE: plain, Shift and Control arrows OK (application=\(application))"); fflush(stdout)
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

#endif
