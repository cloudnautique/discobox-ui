import AppKit
import WebKit
import DiscoboxCore

/// Uses a dedicated loopback fixture and a private pasteboard. Never connects
/// through Workspace or opens a real Discobox desktop.
@MainActor enum DesktopSmoke {
    static func run() async {
        do {
            guard let raw = ProcessInfo.processInfo.environment["DISCOBOX_DESKTOP_FIXTURE"], let url = URL(string: raw), url.host == "127.0.0.1", url.scheme == "http" else { throw DiscoboxError("An explicit loopback fixture URL is required") }
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let session = DesktopSession(source: url, title: "Offline desktop smoke", pasteboard: board)
            defer { session.close() }
            session.window.orderFront(nil)
            for _ in 0..<100 where !session.ready { try await Task.sleep(for: .milliseconds(100)) }
            guard session.ready else { throw DiscoboxError(session.error ?? "WebKit fixture never became ready") }
            let text = "Mac café 👋\nquote: \" \\ end"
            board.setString(text, forType: .string)
            session.terminalShortcuts = true
            session.window.makeKeyAndOrderFront(nil)
            session.window.makeFirstResponder(session.web)
            let pasteKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: session.window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            guard session.web.performKeyEquivalent(with: pasteKey) else { throw DiscoboxError("Command-V was not handled by the desktop") }
            try await Task.sleep(for: .milliseconds(200))
            let pasted = try await session.web.evaluateJavaScript("window.fixture.pasted") as? String
            guard pasted == text else { throw DiscoboxError("Clipboard paste did not preserve text") }
            let shifted = try await session.web.evaluateJavaScript("window.fixture.keys.some(k => k[0] === 65505 && k[2] === true)") as? Bool
            guard shifted == true else { throw DiscoboxError("Terminal paste omitted Shift") }
            session.syncClipboard = false
            session.command("c")
            try await Task.sleep(for: .milliseconds(200))
            guard board.string(forType: .string) == "Remote café\nsecond line" else { throw DiscoboxError("Explicit remote copy did not update the private Mac pasteboard") }
            print("DESKTOP_SMOKE_OK: WebKit module adapter, Command-V, Unicode/multiline Mac-to-remote text, terminal modifier, remote-to-Mac text with auto-sync off")
            fflush(stdout); session.close(); exit(0)
        } catch { print("DESKTOP_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
}
