import AppKit
import SwiftUI
import DiscoboxCore

/// Uses the real sidebar with offline servers. The automated check verifies
/// native action registration and table lifetime; the manual mode exercises a
/// physical trackpad, which synthetic scroll events do not faithfully emulate.
@MainActor enum SidebarSwipeSmoke {
    static func run() async {
        let hub = Connections(polling: false), resources = ConnectionRuntimes()
        let suite = "ai.discobox.smoke.swipe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("none", forKey: "boxGrouping")
        let commands = WorkspaceCommands(defaults: defaults)
        defer { hub.disconnectAll(); resources.closeAll(); defaults.removePersistentDomain(forName: suite) }
        do {
            let local = try await hub.connect(.thisComputer, demo: true) { DemoClient() }
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: ConnectedWorkspace(connections: hub, runtimes: resources, commands: commands).defaultAppStorage(defaults))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            try await wait { table(in: window)?.numberOfRows ?? 0 > 0 }
            let original = table(in: window)!
            try await wait { actions(original, edge: .leading).contains("Start") && actions(original, edge: .leading).contains("Stop") }
            guard actions(original, edge: .trailing).contains("Archive") else { throw DiscoboxError("Native Archive action missing") }

            if ProcessInfo.processInfo.arguments.contains("--sidebar-manual-swipe-smoke") {
                NSApp.activate(ignoringOtherApps: true)
                window.title = "Swipe diagnostic — demo boxes only"
                let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    if event.window === window {
                        print("SWIPE_EVENT x=\(event.scrollingDeltaX) y=\(event.scrollingDeltaY) phase=\(event.phase.rawValue)")
                        fflush(stdout)
                    }
                    return event
                }
                defer { if let monitor { NSEvent.removeMonitor(monitor) } }
                print("SWIPE_DEMO_READY"); fflush(stdout)
                for _ in 0..<3600 {
                    if !window.isVisible { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } else {
                let remote = try await hub.connect(.init(name: "Remote fixture", endpoint: "https://remote.example.invalid"), demo: true) { DemoClient() }
                try await wait { table(in: window) === original && actions(original, edge: .leading).filter { $0 == "Start" }.count == 2 }
                await local.workspace.refresh()
                hub.activate(local.id)
                try await wait { table(in: window) === original && actions(original, edge: .leading).filter { $0 == "Start" }.count == 2 }
                try await remote.workspace.performBoxAction(.start, boxID: "demo-api", connection: remote.workspace.connectionID)
                try await wait { actions(original, edge: .leading).filter { $0 == "Start" }.count == 1 && actions(original, edge: .leading).filter { $0 == "Stop" }.count == 3 }
                print("SIDEBAR_SWIPE_SMOKE_OK: native Start/Stop/Archive registration, same table across host switches, updated actions after state changes; physical gesture not simulated")
            }
            fflush(stdout); exit(0)
        } catch { print("SIDEBAR_SWIPE_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    private static func actions(_ table: NSTableView, edge: NSTableView.RowActionEdge) -> [String] {
        (0..<table.numberOfRows).flatMap { row in
            (table.delegate?.tableView?(table, rowActionsForRow: row, edge: edge) ?? []).map(\.title)
        }
    }
    private static func table(in window: NSWindow) -> NSTableView? {
        window.contentView.flatMap { views($0).compactMap { $0 as? NSTableView }.first }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DiscoboxError("Native sidebar check timed out")
    }
}
