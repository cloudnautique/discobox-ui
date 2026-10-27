import AppKit
import SwiftUI
import DiscoboxCore

/// Layout/fixture validation that does not require a key window or keyboard
/// injection. Useful when WindowServer will not activate a second app instance.
@MainActor enum FeatureSmoke {
    static func run() async {
        do {
            let workspace = Workspace()
            await workspace.connect(client: DemoClient(pendingRequests: true), label: "Offline panels", demo: true)
            await workspace.selectBox("demo-ui")
            await workspace.refreshApprovals()
            guard let item = workspace.approvals.first else { throw DiscoboxError("Missing approval fixture") }
            guard let box = workspace.selectedBox else { throw DiscoboxError("Missing box fixture") }
            let sidebarWorkspace = Workspace()
            await sidebarWorkspace.connect(client: DemoClient(), label: "Offline sidebar", demo: true)
            let panels: [(String, AnyView)] = [
                ("sidebar", AnyView(WorkspaceView().environment(sidebarWorkspace).environment(WorkspaceCommands()))),
                ("box-list", AnyView(List(workspace.visibleBoxes) { BoxRow(box: $0) }.listStyle(.sidebar).environment(workspace))),
                ("archive", AnyView(BoxActionSheet(request: .init(box: box, action: .archive, connection: workspace.connectionID)).environment(workspace))),
                ("purge", AnyView(BoxActionSheet(request: .init(box: box, action: .purge, connection: workspace.connectionID)).environment(workspace))),
                ("approval", AnyView(ApprovalSheet(item: item).environment(workspace))),
                ("new-box", AnyView(NewBoxSheet().environment(workspace))),
                ("tools", AnyView(ToolsSheet().environment(workspace))),
                ("services", AnyView(ServicesView().environment(workspace).environment(ServiceForwards()))),
                ("files", AnyView(FilesView().environment(workspace)))
            ]
            for (name, panel) in panels {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                let view = NSHostingView(rootView: panel.environment(TerminalStore()).environment(ServiceForwards()).environment(DesktopWindows()))
                window.contentView = view
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(500))
                view.layoutSubtreeIfNeeded()
                guard view.bounds.width > 0, view.bounds.height > 0 else { throw DiscoboxError("Collapsed \(name) panel") }
                if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
                }
                window.orderOut(nil)
            }
            try await workspace.answer(item, action: "approve", payload: .object(["grantTTLSeconds": .number(900)]))
            guard workspace.approvals.isEmpty else { throw DiscoboxError("Answer did not clear fixture inbox") }
            print("FEATURE_SMOKE_OK: box rows, lifecycle confirmations, approval, new-box prompt, tools and file panel layout; fixture answer clears inbox")
            fflush(stdout); exit(0)
        } catch { print("FEATURE_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }
}
