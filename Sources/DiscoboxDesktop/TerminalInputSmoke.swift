import AppKit
import GhosttyKit
import DiscoboxCore

/// Native input profiling with a synthetic raw-PTY echo child only. This path
/// exits before saved connections, Keychain or any backend are initialized.
@MainActor enum TerminalInputSmoke {
    static func run() async {
        let session = TerminalSession(arguments: ["--terminal-demo"])
        let workspace = Workspace()
        let commands = WorkspaceCommands()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Discobox offline input latency check"
        window.contentView = session.view
        defer { commands.cancelPrefix(); session.close(); workspace.disconnect(); window.orderOut(nil) }
        do {
            await workspace.connect(client: DemoClient(), label: "Offline input fixture", demo: true)
            commands.window = window
            commands.install(workspace: workspace)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(session.view)
            try await wait { session.view.outputText().contains("Unicode: café 日本語") }
            guard session.error == nil, session.view.surface != nil else {
                throw DiscoboxError(session.error ?? "Terminal surface unavailable")
            }
            var expected = "> "
            var calls: [Double] = [], directRoundTrips: [Double] = [], queuedRoundTrips: [Double] = []
            for index in 0..<60 {
                // Separate idle keystrokes, not a paste or a batch sent at once.
                try await Task.sleep(for: .milliseconds(12))
                let character = index.isMultiple(of: 2) ? "x" : "y"
                let code: UInt16 = index.isMultiple(of: 2) ? 7 : 16
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: code)!
                let start = DispatchTime.now().uptimeNanoseconds
                if index < 30 {
                    session.view.keyDown(with: event)
                    calls.append(milliseconds(since: start))
                } else {
                    // The second batch traverses the native event loop and the
                    // installed workspace key monitor before reaching Ghostty.
                    NSApp.postEvent(event, atStart: false)
                }
                expected += character
                try await wait { session.view.outputText().contains(expected) }
                if index < 30 { directRoundTrips.append(milliseconds(since: start)) }
                else { queuedRoundTrips.append(milliseconds(since: start)) }
                let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: code)!
                if index < 30 { session.view.keyUp(with: up) }
                else { NSApp.postEvent(up, atStart: false) }
            }
            print("TERMINAL_INPUT_KEYDOWN_MS " + summary(calls))
            print("TERMINAL_INPUT_DIRECT_SCREEN_STATE_MS " + summary(directRoundTrips))
            print("TERMINAL_INPUT_QUEUED_SCREEN_STATE_MS " + summary(queuedRoundTrips))
            print("TERMINAL_INPUT_SMOKE_OK: 30 direct and 30 queued native key events echoed through Ghostty and a raw PTY without newline; timings include 2ms snapshot polling, exclude physical display presentation")
            session.close(); workspace.disconnect(); window.orderOut(nil)
            fflush(stdout); exit(0)
        } catch {
            print("TERMINAL_INPUT_SMOKE_FAILED: \(error)")
            session.close(); workspace.disconnect(); window.orderOut(nil)
            fflush(stdout); exit(1)
        }
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private static func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return String(format: "p50=%.3f p95=%.3f max=%.3f", sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last ?? 0)
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw DiscoboxError("Offline input did not reach the terminal screen within five seconds")
    }
}
