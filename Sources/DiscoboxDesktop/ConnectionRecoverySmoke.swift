import AppKit
import SwiftUI
import DiscoboxCore

/// Offline recovery UI and PTY checks. Never loads saved connections, Keychain,
/// real notification services, or an operator's Discobox backend.
@MainActor enum ConnectionRecoverySmoke {
    static func run(includeTerminal: Bool = false) async {
        let workspace = Workspace(), client = RecoveryDesktopFixture(), terminals = TerminalStore()
        defer { workspace.disconnect(); terminals.closeAll() }
        do {
            await workspace.connect(client: client, label: "Recovery fixture", demo: true)
            await workspace.selectBox("demo-ui")
            let cached = workspace.sandboxes
            await client.setOnline(false); await workspace.refresh()
            guard workspace.recovery.nextRetryAt != nil, workspace.sandboxes == cached else { throw DiscoboxError("Recovery dropped the cached inventory") }
            for (name, scheme) in [("recovery-waiting-light", ColorScheme.light), ("recovery-waiting-dark", .dark)] {
                try await panel(name: name, workspace: workspace, scheme: scheme)
            }
            await client.setOnline(true); await workspace.retryConnection()
            guard workspace.connectionError == nil, workspace.sandboxID == "demo-ui", let inventory = workspace.terminalInventory else {
                throw DiscoboxError("Recovery did not restore the selected box")
            }
            if includeTerminal { try verifyTerminalRecovery(workspace: workspace, inventory: inventory, terminals: terminals) }
            await client.denyAccess(); await workspace.refresh()
            guard workspace.recovery.requiresAction else { throw DiscoboxError("Authorization failure kept retrying") }
            try await panel(name: "recovery-attention-light", workspace: workspace, scheme: .light)
            try await panel(name: "recovery-attention-dark", workspace: workspace, scheme: .dark)
            workspace.disconnect(); terminals.closeAll()
            print("CONNECTION_RECOVERY_SMOKE_OK: themed recovery controls fit; cached boxes and selection survive an outage; authorization pauses retries")
            fflush(stdout); exit(0)
        } catch { print("CONNECTION_RECOVERY_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    private static func verifyTerminalRecovery(workspace: Workspace, inventory: Workspace.TerminalInventory, terminals: TerminalStore) throws {
        let identity = TerminalIdentity(connection: workspace.connectionID, endpoint: "offline", project: inventory.project, box: inventory.box, exec: "agent-1", demo: true)
        let live = terminals.session(identity)
        guard live.view.surface != nil, live.error == nil else { throw DiscoboxError("Offline terminal fixture did not create a surface: " + (live.error ?? GhosttyRuntime.shared.error ?? "unknown renderer error")) }
        // Simulate only the child stream ending; the server-side exec is
        // still in the newly confirmed live inventory.
        live.ended = true
        terminals.recoverInterrupted(inventory, connection: workspace.connectionID)
        let replacement = terminals.session(identity)
        guard replacement !== live, live.view.surface == nil, replacement.view.surface != nil else {
            throw DiscoboxError("Confirmed live exec did not get a new attachment")
        }
        terminals.recoverInterrupted(inventory, connection: workspace.connectionID)
        guard terminals.session(identity) === replacement else { throw DiscoboxError("Healthy terminal was unnecessarily restarted") }
        replacement.ended = true
        terminals.recoverInterrupted(inventory, connection: workspace.connectionID)
        guard terminals.session(identity) === replacement else { throw DiscoboxError("Repeated attachment failure bypassed cooldown") }
        print("CONNECTION_RECOVERY_TERMINAL_SMOKE_OK: ended live PTY reattaches once; healthy streams stay intact; cooldown prevents loops")
    }
    private static func panel(name: String, workspace: Workspace, scheme: ColorScheme) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 230), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
            ConnectionRecoveryBanner(workspace: workspace, computer: "Studio computer", disconnect: {})
            HStack { Text("Last-known boxes: \(workspace.sandboxes.count)"); Spacer(); ConnectionStatusBadge(workspace: workspace) }.font(.caption).padding(.horizontal, 16)
            Spacer()
        }.frame(width: 680, height: 230).background(DiscoboxAppearance.surface).preferredColorScheme(scheme))
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        guard buttons.count >= 2 else { throw DiscoboxError("Recovery actions are missing") }
        for button in buttons {
            let bounds = button.convert(button.bounds, to: view)
            guard view.bounds.contains(NSPoint(x: bounds.midX, y: bounds.midY)) else { throw DiscoboxError("Recovery action clipped outside the window") }
        }
        if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private actor RecoveryDesktopFixture: DiscoboxClient {
    private let demo = DemoClient()
    private var online = true
    private var denied = false
    func setOnline(_ value: Bool) { online = value }
    func denyAccess() { denied = true }
    func perform(_ request: BridgeRequest) async throws -> Data {
        guard online else { throw URLError(.notConnectedToInternet) }
        guard !denied else { throw DiscoboxError("Access refused (403)") }
        return try await demo.perform(request)
    }
}
