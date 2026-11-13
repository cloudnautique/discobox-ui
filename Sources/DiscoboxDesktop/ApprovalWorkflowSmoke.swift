import AppKit
import SwiftUI
import DiscoboxCore

/// Native controls against injected, offline fixtures only. No live server,
/// Keychain identity, OS notification, or terminal renderer is initialized.
@MainActor enum ApprovalWorkflowSmoke {
    static func run() async {
        do {
            try await ApprovalDurationSmoke.verify()
            try await ApprovalQueueSmoke.verify()
            try await ModernApprovalSmoke.verify()
            try await DialogReceiptSmoke.verify()
            let workspace = Workspace()
            await workspace.connect(client: DemoClient(pendingRequests: true), label: "Offline workflow", demo: true)
            await workspace.refreshApprovals()
            guard let legacy = workspace.approvals.first else { throw DiscoboxError("Legacy fixture missing") }
            var panels: [(String, AnyView)] = [("legacy-approval", AnyView(ApprovalSheet(item: legacy).environment(workspace)))]
            panels += try await UpstreamIntegrationSmoke.panels()
            let settingsSuite = "ai.discobox.smoke.dropdown-settings." + UUID().uuidString
            let defaults = UserDefaults(suiteName: settingsSuite)!
            defer { defaults.removePersistentDomain(forName: settingsSuite) }
            panels.append(("settings-appearance", AnyView(AppearanceSettings().defaultAppStorage(defaults).frame(width: 640, height: 680))))
            panels.append(("settings-keybindings", AnyView(KeybindingSettings().environment(WorkspaceCommands(defaults: defaults)).frame(width: 640, height: 680))))
            panels.append(("settings-connection-editor", AnyView(ConnectionEditor(profile: nil, save: { _ in }).defaultAppStorage(defaults))))
            let secret: JSONValue = .object(["id": .string("fixture-secret"), "name": .string("Project API token"), "maxBindingTTLSeconds": .number(3600), "routes": .array([.object(["hosts": .array([.string("api.example.test")])])])])
            panels.append(("credential-shared-limits", AnyView(CredentialDetailsView(request: .init(secret: secret, connection: workspace.connectionID), saved: {}).environment(workspace))))
            for mode in [DiscoboxAppearance.Mode.light, .dark] {
                DiscoboxAppearance.apply(mode)
                for (name, panel) in panels {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.contentView = NSHostingView(rootView: panel)
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(200))
                    if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"], let root = window.contentView,
                       let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + "-" + mode.rawValue + ".png")
                        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                    }
                    window.orderOut(nil)
                }
            }
            workspace.disconnect()
            print("APPROVAL_WORKFLOW_SMOKE_OK: direct footer approval, capped durations, actionable receipts, queued modern decisions, shared-limit editor, and light/dark harness reviews")
            fflush(stdout); exit(0)
        } catch { print("APPROVAL_WORKFLOW_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
}

@MainActor enum NativeApprovalControls {
    static func reviewControl(_ window: NSWindow) -> NSButton? {
        guard let root = window.contentView, let scroll = views(root).compactMap({ $0 as? NSScrollView }).first else { return nil }
        if let checkbox = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityRole() == .checkBox && $0.enclosingScrollView == nil }) { return checkbox }
        let content = scroll.convert(scroll.bounds, to: root)
        return views(root).compactMap { $0 as? NSButton }.filter { button in
            let rect = button.convert(button.bounds, to: root)
            return root.isFlipped ? rect.midY > content.maxY : rect.midY < content.minY
        }.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: root).midY
            let right = rhs.convert(rhs.bounds, to: root).midY
            return root.isFlipped ? left < right : left > right
        }.first
    }
    static func click(_ button: NSButton, window: NSWindow) throws {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        guard window.contentLayoutRect.contains(point) else { throw DiscoboxError("Review checkbox is outside the visible form") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw DiscoboxError("Could not create native fixture event") }
            NSApp.postEvent(event, atStart: false)
        }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
}
