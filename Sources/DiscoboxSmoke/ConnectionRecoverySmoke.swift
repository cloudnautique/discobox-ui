#if DEBUG
@testable import DiscoboxUI
import AppKit
import SwiftUI
import DiscoboxCore

/// Offline recovery UI and PTY checks. Never loads saved connections, Keychain,
/// real notification services, or an operator's Discobox backend.
@MainActor enum ConnectionRecoverySmoke {
    static func run(includeTerminal: Bool = false) async {
        let workspace = ConnectionSession(), client = RecoveryDesktopFixture(), terminals = TerminalStore()
        defer { workspace.disconnect(); terminals.closeAll() }
        do {
            await workspace.connect(client: client, label: "Recovery fixture", demo: true)
            await workspace.selection.selectBox("demo-ui")
            let cached = workspace.inventory.sandboxes
            await client.setOnline(false); await workspace.refresh()
            guard workspace.connectionState.recovery.nextRetryAt != nil, workspace.inventory.sandboxes == cached else { throw DiscoboxError("Recovery dropped the cached inventory") }
            for (name, scheme) in [("recovery-waiting-light", ColorScheme.light), ("recovery-waiting-dark", .dark)] {
                try await panel(name: name, workspace: workspace, scheme: scheme)
            }
            await client.setOnline(true); await workspace.retryConnection()
            guard workspace.connectionState.connectionError == nil, workspace.selection.sandboxID == "demo-ui", let inventory = workspace.selection.terminalInventory else {
                throw DiscoboxError("Recovery did not restore the selected box")
            }
            if includeTerminal { try verifyTerminalRecovery(workspace: workspace, inventory: inventory, terminals: terminals) }
            await client.denyAccess(); await workspace.refresh()
            guard workspace.connectionState.recovery.requiresAction else { throw DiscoboxError("Authorization failure kept retrying") }
            try await panel(name: "recovery-attention-light", workspace: workspace, scheme: .light)
            try await panel(name: "recovery-attention-dark", workspace: workspace, scheme: .dark)
            try await verifyWorkspaceBanner()
            workspace.disconnect(); terminals.closeAll()
            print("CONNECTION_RECOVERY_SMOKE_OK: themed recovery controls fit; cached boxes and selection survive an outage; authorization pauses retries")
            fflush(stdout); exit(0)
        } catch { print("CONNECTION_RECOVERY_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
    /// Check the actual split workspace, not just a banner rendered in isolation.
    private static func verifyWorkspaceBanner() async throws {
        let client = RecoveryDesktopFixture()
        let fixture = try await WorkspaceFixture.make(client: client)
        let workspace = fixture.connections.active
        await workspace.selection.selectBox("demo-api")
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil); fixture.close() }
        for scheme in [ColorScheme.light, .dark] {
            window.contentView = NSHostingView(rootView: fixture.view.preferredColorScheme(scheme).frame(width: 1200, height: 800))
            window.orderFront(nil)
            guard let root = window.contentView else { throw DiscoboxError("Missing fixture content") }
            try await wait { sidebarSplit(in: root) != nil }
            let split = sidebarSplit(in: root)!
            let table = descendants(root).compactMap { $0 as? NSTableView }.first!
            root.layoutSubtreeIfNeeded()
            let healthyTop = split.convert(split.bounds, to: nil).maxY

            await client.setOnline(false); await workspace.refresh()
            try await wait { split.convert(split.bounds, to: nil).maxY < healthyTop - 50 }
            let bannerActions = descendants(root).compactMap { $0 as? NSButton }.filter {
                let frame = $0.convert($0.bounds, to: nil)
                return !$0.isHiddenOrHasHiddenAncestor && root.convert(root.bounds, to: nil).contains(frame)
                    && frame.minY >= split.convert(split.bounds, to: nil).maxY
            }
            guard bannerActions.count == 2 else {
                throw DiscoboxError("Expected both connection actions above the native workspace split; found \(bannerActions.count)")
            }
            let recoveryTop = split.convert(split.bounds, to: nil).maxY
            workspace.selection.commandError = "Fixture command could not finish."
            try await wait { split.convert(split.bounds, to: nil).maxY < recoveryTop - 20 }
            workspace.selection.commandError = nil

            await client.setOnline(true); await workspace.retryConnection()
            try await wait { workspace.connectionState.connectionError == nil && abs(split.convert(split.bounds, to: nil).maxY - healthyTop) < 2 }
            await client.denyAccess("Unsupported companion protocol version. " + String(repeating: "Long fixture diagnostic. ", count: 60))
            await workspace.refresh()
            try await wait { workspace.connectionState.connectionError != nil && split.convert(split.bounds, to: nil).maxY < healthyTop - 50 }
            guard healthyTop - split.convert(split.bounds, to: nil).maxY < 160,
                  descendants(root).compactMap({ $0 as? NSTableView }).first === table,
                  workspace.selection.sandboxID == "demo-api" else {
                throw DiscoboxError("Recovery notice consumed unbounded height or replaced the sidebar/selection")
            }
            await client.allowAccess(); await workspace.retryConnection()
            try await wait { workspace.connectionState.connectionError == nil && abs(split.convert(split.bounds, to: nil).maxY - healthyTop) < 2 }
        }
        print("RECOVERY_LAYOUT_SMOKE_OK: warning and command rows reserve space above the native split, long diagnostics stay bounded, recovery restores height and retains sidebar/selection in both themes")
    }
    private static func sidebarSplit(in root: NSView) -> NSSplitView? {
        var parent = descendants(root).compactMap { $0 as? NSTableView }.first?.superview
        while let view = parent {
            if let split = view as? NSSplitView, split.isVertical { return split }
            parent = view.superview
        }
        return nil
    }
    private static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw DiscoboxError("Recovery layout did not settle at line \(line)")
    }
    private static func verifyTerminalRecovery(workspace: ConnectionSession, inventory: BoxSelectionStore.TerminalInventory, terminals: TerminalStore) throws {
        let identity = TerminalIdentity(connection: workspace.connectionState.connectionID, endpoint: "offline", project: inventory.project, box: inventory.box, exec: "agent-1", demo: true)
        let live = terminals.session(identity)
        guard live.view.surface != nil, live.error == nil else { throw DiscoboxError("Offline terminal fixture did not create a surface: " + (live.error ?? GhosttyRuntime.shared.error ?? "unknown renderer error")) }
        // Simulate only the child stream ending; the server-side exec is
        // still in the newly confirmed live inventory.
        live.ended = true
        terminals.recoverInterrupted(inventory, connection: workspace.connectionState.connectionID)
        let replacement = terminals.session(identity)
        guard replacement !== live, live.view.surface == nil, replacement.view.surface != nil else {
            throw DiscoboxError("Confirmed live exec did not get a new attachment")
        }
        terminals.recoverInterrupted(inventory, connection: workspace.connectionState.connectionID)
        guard terminals.session(identity) === replacement else { throw DiscoboxError("Healthy terminal was unnecessarily restarted") }
        replacement.ended = true
        terminals.recoverInterrupted(inventory, connection: workspace.connectionState.connectionID)
        guard terminals.session(identity) === replacement else { throw DiscoboxError("Repeated attachment failure bypassed cooldown") }
        print("CONNECTION_RECOVERY_TERMINAL_SMOKE_OK: ended live PTY reattaches once; healthy streams stay intact; cooldown prevents loops")
    }
    private static func panel(name: String, workspace: ConnectionSession, scheme: ColorScheme) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 230), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
            ConnectionRecoveryBanner(workspace: workspace, computer: "Studio computer", disconnect: {})
            HStack { Text("Last-known boxes: \(workspace.inventory.sandboxes.count)"); Spacer(); ConnectionStatusBadge(workspace: workspace) }.font(.caption).padding(.horizontal, 16)
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
    private var denial = "Access refused (403)"
    func setOnline(_ value: Bool) { online = value }
    func denyAccess(_ message: String = "Access refused (403)") { denied = true; denial = message }
    func allowAccess() { denied = false }
    func perform(_ request: BridgeRequest) async throws -> Data {
        guard online else { throw URLError(.notConnectedToInternet) }
        guard !denied else { throw DiscoboxError(denial) }
        return try await demo.perform(request)
    }
}

#endif
