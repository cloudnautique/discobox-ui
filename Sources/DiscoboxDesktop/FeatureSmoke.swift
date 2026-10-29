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
            // Retained forwarding sessions must follow A → B → A without
            // reusing another box's listener inventory.
            let forwards = ServiceForwards()
            let first = forwards.session(box: "demo-ui", workspace: workspace)
            let second = forwards.session(box: "demo-api", workspace: workspace)
            guard first !== second else { throw DiscoboxError("Boxes shared a forwarding session") }
            for id in ["demo-ui", "demo-api", "demo-ui", "demo-api", "demo-ui"] {
                await workspace.selectBox(id)
                let expected = id == "demo-ui" ? first : second
                guard forwards.existingSession(box: id, workspace: workspace) === expected else {
                    throw DiscoboxError("Forwarding inventory did not follow box selection")
                }
            }
            forwards.close(box: "demo-api")
            guard forwards.existingSession(box: "demo-api", workspace: workspace) == nil,
                  forwards.existingSession(box: "demo-ui", workspace: workspace) === first else {
                throw DiscoboxError("Closing one box affected another box's forwards")
            }
            forwards.closeAll()
            let sidebarWorkspace = Workspace()
            await sidebarWorkspace.connect(client: DemoClient(), label: "Offline sidebar", demo: true)
            let settingsSuite = "ai.discobox.smoke.connections." + UUID().uuidString
            let settingsDefaults = UserDefaults(suiteName: settingsSuite)!
            defer { settingsDefaults.removePersistentDomain(forName: settingsSuite) }
            settingsDefaults.set(ConnectionProfiles.encode([
                .init(name: "Studio", endpoint: "discobox://d1-fixture"),
                .init(name: "Build server", endpoint: "https://build.example.com")
            ]), forKey: "savedConnections")
            let archivedWorkspace = Workspace()
            await archivedWorkspace.connect(client: DemoClient(), label: "Offline archives", demo: true)
            for id in ["demo-api", "demo-tests"] {
                try await archivedWorkspace.performBoxAction(.archive, boxID: id, connection: archivedWorkspace.connectionID)
            }
            archivedWorkspace.filter = .archived
            let archives = archivedWorkspace.visibleBoxes
            let computers = Connections(polling: false)
            let localComputer = try await computers.connect(.thisComputer, demo: true) { DemoClient() }
            let studioComputer = try await computers.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { DemoClient(pendingRequests: true) }
            await studioComputer.workspace.refreshApprovals()
            computers.activate(localComputer.id)
            let computerResources = ConnectionRuntimes()
            let panels: [(String, AnyView)] = [
                ("computers", AnyView(ConnectedWorkspace(connections: computers, runtimes: computerResources, commands: WorkspaceCommands(defaults: settingsDefaults)).defaultAppStorage(settingsDefaults))),
                ("new-box-computer", AnyView(NewBoxSheet().environment(localComputer.workspace).environment(computers))),
                ("archived-sidebar", AnyView(WorkspaceView().environment(archivedWorkspace).environment(WorkspaceCommands()).defaultAppStorage(settingsDefaults))),
                ("bulk-purge", AnyView(BulkPurgeSheet(request: .init(boxes: archives, connection: archivedWorkspace.connectionID), completed: { _ in }).environment(archivedWorkspace))),
                ("connections", AnyView(ConnectionSettings().environment(workspace).defaultAppStorage(settingsDefaults).frame(width: 640, height: 680))),
                ("connection-editor", AnyView(ConnectionEditor(profile: nil, save: { _ in }))),
                ("connection-edit", AnyView(ConnectionEditor(profile: .init(name: "Studio", endpoint: "discobox://d1-0000000-1111111-2222222-3333333-4444444-5555555-6666666-7777777?addr=192.0.2.10:12345"), save: { _ in }))),
                ("sidebar", AnyView(WorkspaceView().environment(sidebarWorkspace).environment(WorkspaceCommands()))),
                ("box-list", AnyView(List(workspace.visibleBoxes) { BoxRow(box: $0) }.listStyle(.sidebar).environment(workspace))),
                ("archive", AnyView(BoxActionSheet(request: .init(box: box, action: .archive, connection: workspace.connectionID)).environment(workspace))),
                ("purge", AnyView(BoxActionSheet(request: .init(box: box, action: .purge, connection: workspace.connectionID)).environment(workspace))),
                ("approval", AnyView(ApprovalSheet(item: item).environment(workspace))),
                ("new-box", AnyView(NewBoxSheet().environment(workspace))),
                ("tools", AnyView(ToolsSheet().environment(workspace))),
                ("audit", AnyView(AuditView(boxID: box.id).environment(workspace))),
                ("services", AnyView(ServicesView(box: box).environment(workspace).environment(ServiceForwards()))),
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
