import AppKit
import SwiftUI
import DiscoboxCore
import UserNotifications

/// Layout/fixture validation that does not require a key window or keyboard
/// injection. Useful when WindowServer will not activate a second app instance.
@MainActor enum FeatureSmoke {
    static func run() async {
        do {
            try await verifyAppearance()
            try await StudioModalSmoke.verify()
            try await verifyNotifications()
            try await DialogReceiptSmoke.verify()
            try await FilesSmoke.verify()
            try await verifyNotificationPermissionRecovery()
            try await verifyBackgroundNotificationRecovery()
            try await verifyComputerUsage()
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
            await workspace.refreshResources()
            await localComputer.workspace.refreshResources()
            guard let resourcePool = workspace.resources.pools.first else { throw DiscoboxError("Resource fixture missing") }
            guard let shell = workspace.execs.first(where: \.isShell) else { throw DiscoboxError("Shell fixture missing") }
            guard let stoppedBox = workspace.sandboxes.first(where: { $0.id == "demo-api" }) else { throw DiscoboxError("Stopped-box fixture missing") }
            let credentialDraft = LaunchCredentialDraft(environment: "OBOT_MCP_TOKEN", host: "demo.on-obot.ai", token: "fixture-not-a-real-token")
            let inboxWorkspace = Workspace()
            await inboxWorkspace.connect(client: StudioInboxFixture(), label: "Offline approvals", demo: true)
            await inboxWorkspace.refreshApprovals()
            let toolsWorkspace = Workspace()
            await toolsWorkspace.connect(client: StudioInboxFixture(), label: "Offline tools", demo: true)
            await toolsWorkspace.selectBox("demo-ui")
            await localComputer.workspace.refreshUsage(); await studioComputer.workspace.refreshUsage()
            let notificationSettings = ApprovalNotifications(service: NotificationPermissionFixture(), defaults: settingsDefaults)
            let deniedService = NotificationPermissionFixture(); deniedService.status = .denied
            let deniedSettings = ApprovalNotifications(service: deniedService, defaults: settingsDefaults)
            let maintenanceBoxes = try JSONDecoder().decode([Sandbox].self, from: Data(#"""
                [
                  {"id":"upgrade","projectId":"p","displayName":"Update available","config":{"model":"Claude Code"},"runtime":{"state":"ready","displayState":"running","upgrade":{"available":true,"targetImage":"fixture:next"}}},
                  {"id":"repair","projectId":"p","displayName":"Container needs repair","config":{"model":"Codex"},"runtime":{"state":"failed","displayState":"error","errorMessage":"The container could not be created."}},
                  {"id":"both","projectId":"p","displayName":"Pinned image unavailable","config":{"model":"Claude Code"},"runtime":{"state":"failed","displayState":"error","errorReason":"image_unavailable","upgrade":{"available":true}}},
                  {"id":"repairing","projectId":"p","displayName":"Repair in progress","config":{"model":"Codex"},"runtime":{"state":"failed","displayState":"repairing"}},
                  {"id":"healthy","projectId":"p","displayName":"Healthy box","config":{"model":"Claude Code"},"runtime":{"state":"ready","displayState":"running"}}
                ]
                """#.utf8))
            let panels: [(String, AnyView)] = [
                ("box-maintenance-light", AnyView(List(maintenanceBoxes) { BoxRow(box: $0) }.listStyle(.sidebar).frame(width: 350, height: 420).environment(workspace).preferredColorScheme(.light))),
                ("box-maintenance-dark", AnyView(List(maintenanceBoxes) { BoxRow(box: $0) }.listStyle(.sidebar).frame(width: 350, height: 420).environment(workspace).preferredColorScheme(.dark))),
                ("launch-credentials-light", AnyView(NewBoxCredentialsSection(drafts: .constant([credentialDraft]), initiallyExpanded: true).padding(24).frame(width: 560).background(DiscoboxAppearance.surface).preferredColorScheme(.light))),
                ("launch-credentials-dark", AnyView(NewBoxCredentialsSection(drafts: .constant([credentialDraft]), initiallyExpanded: true).padding(24).frame(width: 560).background(DiscoboxAppearance.surface).preferredColorScheme(.dark))),
                ("start-box-light", AnyView(BoxStartPrompt(intent: .init(workspace: workspace, box: stoppedBox, computer: "Studio"), cancel: {}, viewSaved: {}, open: {}).preferredColorScheme(.light))),
                ("start-box-dark", AnyView(BoxStartPrompt(intent: .init(workspace: workspace, box: stoppedBox, computer: "Studio"), cancel: {}, viewSaved: {}, open: {}).preferredColorScheme(.dark))),
                ("studio-light", AnyView(ConnectedWorkspace(connections: computers, runtimes: computerResources, commands: WorkspaceCommands(defaults: settingsDefaults)).defaultAppStorage(settingsDefaults).preferredColorScheme(.light))),
                ("studio-dark", AnyView(ConnectedWorkspace(connections: computers, runtimes: computerResources, commands: WorkspaceCommands(defaults: settingsDefaults)).defaultAppStorage(settingsDefaults).preferredColorScheme(.dark))),
                ("shell-close", AnyView(TerminalCloseSheet(request: .init(terminal: shell, box: box.id, connection: workspace.connectionID), confirm: {}).defaultAppStorage(settingsDefaults))),
                ("appearance", AnyView(AppearanceSettings().defaultAppStorage(settingsDefaults).frame(width: 640, height: 680))),
                ("notifications", AnyView(ApprovalNotificationSettings().frame(width: 640, height: 680))),
                ("resources", AnyView(PoolResourcesView(computer: "Fixture computer").environment(workspace))),
                ("cache-clear", AnyView(PoolCacheClearSheet(request: .init(pool: resourcePool, connection: workspace.connectionID), computer: "Fixture computer").environment(workspace))),
                ("computers", AnyView(ConnectedWorkspace(connections: computers, runtimes: computerResources, commands: WorkspaceCommands(defaults: settingsDefaults)).defaultAppStorage(settingsDefaults))),
                ("new-box-computer", AnyView(NewBoxSheet().environment(localComputer.workspace).environment(computers))),
                ("new-box-light", AnyView(NewBoxSheet().environment(localComputer.workspace).environment(computers).preferredColorScheme(.light))),
                ("new-box-dark", AnyView(NewBoxSheet().environment(localComputer.workspace).environment(computers).preferredColorScheme(.dark))),
                ("switch-box-light", AnyView(BoxChooser().environment(localComputer.workspace).environment(computers).preferredColorScheme(.light))),
                ("switch-box-dark", AnyView(BoxChooser().environment(localComputer.workspace).environment(computers).preferredColorScheme(.dark))),
                ("archived-sidebar", AnyView(WorkspaceView().environment(archivedWorkspace).environment(WorkspaceCommands()).defaultAppStorage(settingsDefaults))),
                ("bulk-purge", AnyView(BulkPurgeSheet(request: .init(boxes: archives, connection: archivedWorkspace.connectionID), completed: { _ in }).environment(archivedWorkspace))),
                ("bulk-purge-light", AnyView(BulkPurgeSheet(request: .init(boxes: archives, connection: archivedWorkspace.connectionID), completed: { _ in }).environment(archivedWorkspace).preferredColorScheme(.light))),
                ("purge-light", AnyView(BoxActionSheet(request: .init(box: archives[0], action: .purge, connection: archivedWorkspace.connectionID)).environment(archivedWorkspace).preferredColorScheme(.light))),
                ("purge-dark", AnyView(BoxActionSheet(request: .init(box: archives[0], action: .purge, connection: archivedWorkspace.connectionID)).environment(archivedWorkspace).preferredColorScheme(.dark))),
                ("stop-light", AnyView(BoxActionSheet(request: .init(box: box, action: .stop, connection: workspace.connectionID)).environment(workspace).preferredColorScheme(.light))),
                ("stop-dark", AnyView(BoxActionSheet(request: .init(box: box, action: .stop, connection: workspace.connectionID)).environment(workspace).preferredColorScheme(.dark))),
                ("connections", AnyView(ConnectionSettings().environment(workspace).defaultAppStorage(settingsDefaults).frame(width: 640, height: 680))),
                ("connection-editor", AnyView(ConnectionEditor(profile: nil, save: { _ in }))),
                ("connection-edit", AnyView(ConnectionEditor(profile: .init(name: "Studio", endpoint: "discobox://d1-0000000-1111111-2222222-3333333-4444444-5555555-6666666-7777777?addr=192.0.2.10:12345"), save: { _ in }))),
                ("sidebar", AnyView(WorkspaceView().environment(sidebarWorkspace).environment(WorkspaceCommands()))),
                ("box-list", AnyView(List(workspace.visibleBoxes) { BoxRow(box: $0) }.listStyle(.sidebar).environment(workspace))),
                ("archive", AnyView(BoxActionSheet(request: .init(box: box, action: .archive, connection: workspace.connectionID)).environment(workspace))),
                ("purge", AnyView(BoxActionSheet(request: .init(box: box, action: .purge, connection: workspace.connectionID)).environment(workspace))),
                ("approval", AnyView(ApprovalSheet(item: item).environment(workspace))),
                ("approval-light", AnyView(ApprovalSheet(item: item).environment(workspace).preferredColorScheme(.light))),
                ("new-box", AnyView(NewBoxSheet().environment(workspace))),
                ("tools", AnyView(ToolsSheet().environment(workspace))),
                ("audit", AnyView(AuditView(boxID: box.id).environment(workspace))),
                ("services", AnyView(ServicesView(box: box).environment(workspace).environment(ServiceForwards()))),
                ("files", AnyView(FilesView().environment(workspace)))
            ]
            let upstreamPanels = try await UpstreamIntegrationSmoke.panels()
            let auditPanels: [(String, AnyView)] = upstreamPanels + [
                ("audit-tools", AnyView(ToolsSheet().environment(toolsWorkspace))),
                ("audit-tools-empty", AnyView(ToolsSheet().environment(workspace))),
                ("audit-welcome", AnyView(WelcomeView().environment(Workspace()).defaultAppStorage(settingsDefaults).frame(width: 1000, height: 800))),
                ("audit-commands", AnyView(CommandsSheet().environment(WorkspaceCommands(defaults: settingsDefaults)))),
                ("audit-tags", AnyView(TagFilterSheet(choices: ["team=platform", "priority=high"], selected: .constant(["team=platform"]), matchAny: .constant(false)))),
                ("audit-usage-details", AnyView(HarnessUsageDetails().environment(computers).environment(localComputer.workspace))),
                ("audit-inbox-multiple", AnyView(ApprovalInboxView(boxID: nil).environment(inboxWorkspace))),
                ("audit-inbox-empty", AnyView(ApprovalInboxView(boxID: nil).environment(archivedWorkspace))),
                ("audit-file-conflict", AnyView(FileConflictSheet(directory: "/workspace/source", count: 3, resolve: { _ in }))),
                ("audit-connection-editor", AnyView(ConnectionEditor(profile: nil, save: { _ in }))),
                ("audit-resources", AnyView(PoolResourcesView(computer: "Fixture computer").environment(workspace))),
                ("audit-settings-harnesses", AnyView(HarnessSettings().environment(workspace).frame(width: 640, height: 600))),
                ("audit-settings-credentials", AnyView(CredentialSettings().environment(workspace).frame(width: 640, height: 600))),
                ("audit-settings-connections", AnyView(ConnectionSettings().environment(workspace).defaultAppStorage(settingsDefaults).frame(width: 640, height: 680))),
                ("audit-settings-keys", AnyView(KeybindingSettings().environment(WorkspaceCommands(defaults: settingsDefaults)).frame(width: 640, height: 680))),
                ("audit-settings-appearance", AnyView(AppearanceSettings().defaultAppStorage(settingsDefaults).frame(width: 640, height: 680))),
                ("audit-settings-notifications", AnyView(ApprovalNotificationSettings(notifications: notificationSettings).frame(width: 640, height: 680))),
                ("audit-settings-notifications-denied", AnyView(ApprovalNotificationSettings(notifications: deniedSettings).frame(width: 640, height: 680))),
                ("audit-delete-credential", AnyView(StudioMessageSheet(title: "Delete credential?", symbol: "key", message: "Access depending on this credential may stop working. This cannot be undone.", confirmTitle: "Delete", destructive: true, defaultConfirm: false, cancel: {}) {})),
                ("audit-remove-connection", AnyView(StudioMessageSheet(title: "Remove Studio?", symbol: "network", message: "This removes the saved address. Access and any active connection remain available.", confirmTitle: "Remove", destructive: true, defaultConfirm: false, cancel: {}) {})),
                ("audit-notification-error", AnyView(StudioMessageSheet(title: "Approval notification", symbol: "bell.badge", message: "This notification is out of date. Open the current approval inbox on its computer.") {})),
                ("audit-port-error", AnyView(StudioMessageSheet(title: "This box port isn’t forwarded", symbol: "network.slash", message: "Open Services to check the reported ports for this box.") {})),
                ("audit-harness-close", AnyView(StudioMessageSheet(title: "Close harness management?", symbol: "terminal", message: "Unsaved changes in the current editor may be lost.", confirmTitle: "Close Console", destructive: true, defaultConfirm: false, cancel: {}) {})),
                ("audit-clipboard-read", AnyView(StudioMessageSheet(title: "Paste into terminal?", symbol: "doc.on.clipboard", message: "The terminal requested clipboard content. Pasting multiple lines can execute commands.", confirmTitle: "Allow", cancel: {}) {})),
                ("audit-clipboard-write", AnyView(StudioMessageSheet(title: "Allow terminal to replace the clipboard?", symbol: "doc.on.clipboard", message: "The terminal requested permission to replace your Mac’s clipboard.", confirmTitle: "Allow", cancel: {}) {}))
            ]
            let themedPanels = auditPanels.flatMap { name, panel in
                [(name + "-light", AnyView(panel.preferredColorScheme(.light))), (name + "-dark", AnyView(panel.preferredColorScheme(.dark)))]
            }
            for (name, panel) in panels + themedPanels {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                let view = NSHostingView(rootView: panel.environment(TerminalStore()).environment(ServiceForwards()).environment(DesktopWindows()))
                window.contentView = view
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(500))
                view.layoutSubtreeIfNeeded()
                guard view.bounds.width > 0, view.bounds.height > 0 else { throw DiscoboxError("Collapsed \(name) panel") }
                if let directory = ProcessInfo.processInfo.environment["DISCOBOX_SMOKE_SCREENSHOTS"] {
                    let path = directory + "/" + name + ".png"
                    // Window capture includes SwiftUI layers and native controls
                    // that AppKit bitmap caching can leave as blank rectangles.
                    let capture = Process()
                    var captured = false
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
                    do { try capture.run(); capture.waitUntilExit(); captured = capture.terminationStatus == 0 } catch { print("Window capture unavailable: \(error)") }
                    if !captured, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
                window.orderOut(nil)
            }
            inboxWorkspace.disconnect()
            toolsWorkspace.disconnect()
            print("STUDIO_THEME_AUDIT_OK: \(auditPanels.count) additional dialog/settings surfaces checked in both Light and Dark")
            try await workspace.answer(item, action: "approve", payload: .object(["grantTTLSeconds": .number(900)]))
            guard workspace.approvals.isEmpty else { throw DiscoboxError("Answer did not clear fixture inbox") }
            print("FEATURE_SMOKE_OK: pool resources, cache confirmation, box rows, lifecycle confirmations, approval, new-box preflight, tools and file panel layout; fixture answer clears inbox")
            fflush(stdout); exit(0)
        } catch { print("FEATURE_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }

    private static func verifyNotifications() async throws {
        try await ApprovalDurationSmoke.verify()
        // Construct SDK content/categories only. Never contact Notification
        // Center, request permissions, or post a real banner during smoke runs.
        let workspace = Workspace()
        await workspace.connect(client: DemoClient(pendingRequests: true), label: "fixture", demo: true)
        await workspace.refreshApprovals()
        let inbox = ApprovalNoticeInbox()
        guard let notice = inbox.update(computerID: "https://private-host.example.invalid", connection: workspace.connectionID, items: workspace.approvals).added.first else {
            throw DiscoboxError("Missing notification fixture")
        }
        let content = ApprovalNotifications.content(for: notice, computer: "Fixture computer", box: "Fixture box")
        guard content.subtitle == "Fixture computer · Fixture box", content.body.contains("GitHub"),
              content.userInfo.count == 1,
              !(content.userInfo["computer"] as? String ?? "").contains("private-host"),
              !content.body.contains("example/project"),
              let category = ApprovalNotifications.categories.first(where: { $0.identifier == content.categoryIdentifier }),
              category.actions.map(\.identifier) == ["approve", "deny", "later"],
              category.actions[0].options.contains(.authenticationRequired),
              category.actions[1].options.contains(.destructive),
              category.actions[1].options.contains(.authenticationRequired),
              category.actions[2].options.isEmpty,
              ApprovalNotifications.categories.contains(where: { $0.actions.first?.title == "Approve…" && $0.actions.first?.options.contains(.foreground) == true }) else {
            throw DiscoboxError("Notification routing, private payload, or native actions changed")
        }
        workspace.disconnect()
        print("NOTIFICATION_SMOKE_OK: native Approve/Deny/Later actions, authentication options, review category, private payload and Notifications settings; no OS notifications posted")
    }

    private static func verifyComputerUsage() async throws {
        let suite = "ai.discobox.smoke.usage-computers." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "harnessUsageExpanded")
        let computers = Connections(polling: false)
        let localClient = ComputerUsageFixture(percent: 12), remoteClient = ComputerUsageFixture(percent: 83)
        let local = try await computers.connect(.thisComputer, demo: true) { localClient }
        let remote = try await computers.connect(.init(name: "Studio", endpoint: "https://studio.example.invalid"), demo: true) { remoteClient }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil); computers.disconnectAll(); defaults.removePersistentDomain(forName: suite) }
        await local.workspace.refreshUsage(); await remote.workspace.refreshUsage()
        let groups = UsageComputer.connected(computers, fallback: local.workspace)
        guard groups.map(\.id) == [local.id, remote.id], groups[1].name == "Studio",
              groups[0].workspace.usage.snapshots["demo-harness"]?.windows.first?.usedPercent == 12,
              groups[1].workspace.usage.snapshots["demo-harness"]?.windows.first?.usedPercent == 83 else {
            throw DiscoboxError("Computer usage merged hosts with identical harness IDs")
        }
        let localReads = await localClient.usageReads, remoteReads = await remoteClient.usageReads
        for host in [local, remote, local] {
            computers.activate(host.id)
            let panel = VStack {
                HarnessUsageSection()
                HarnessUsageDetails()
            }.environment(computers).environment(host.workspace).defaultAppStorage(defaults)
            let view = NSHostingView(rootView: panel)
            window.contentView = view; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            guard UsageComputer.connected(computers, fallback: host.workspace).map(\.id) == groups.map(\.id), view.bounds.width > 0 else {
                throw DiscoboxError("Computer usage changed scope when selecting another host")
            }
        }
        guard await localClient.usageReads == localReads, await remoteClient.usageReads == remoteReads else {
            throw DiscoboxError("Rendering usage summaries or Details started extra usage reads")
        }
        computers.disconnect(remote.id)
        guard UsageComputer.connected(computers, fallback: local.workspace).map(\.id) == [local.id],
              local.workspace.usage.snapshots["demo-harness"]?.windows.first?.usedPercent == 12 else {
            throw DiscoboxError("Usage disconnect affected the wrong computer")
        }
        print("COMPUTER_USAGE_SMOKE_OK: per-computer names and separate readings for identical harness IDs, selection-independent scope, no extra UI usage reads, disconnected-host cleanup")
    }

    private static func verifyNotificationPermissionRecovery() async throws {
        let suite = "ai.discobox.smoke.notification-permission." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let computers = Connections(polling: false)
        let host = try await computers.connect(.thisComputer, demo: true) { DemoClient(pendingRequests: true) }
        defer { computers.disconnectAll() }
        await host.workspace.refreshApprovals()
        for scenario in ["denied", "request-error", "delivery-error", "refused-grant"] {
            let service = NotificationPermissionFixture()
            switch scenario {
            case "denied": service.status = .denied
            case "request-error": service.status = .notDetermined; service.requestError = true
            case "delivery-error": service.deliveryError = true
            default: service.granted = false
            }
            let notifications = ApprovalNotifications(service: service, defaults: defaults)
            notifications.configure(computers)
            try await waitForNotification { notifications.waitingCount == 1 && !notifications.checkingPermission }
            guard notifications.permissionBlocked, service.delivered.isEmpty,
                  scenario != "denied" || service.authorizationRequests == 0 else {
                throw DiscoboxError("Denied notification permission was ignored: " + scenario)
            }
            service.status = .authorized; service.requestError = false
            service.deliveryError = false; service.granted = true
            await notifications.refreshAuthorization()
            try await waitForNotification { service.delivered.count == 1 && notifications.waitingCount == 0 }
            guard notifications.authorization == .authorized, !notifications.permissionBlocked,
                  notifications.deliveryError == nil else {
                throw DiscoboxError("Recovered permission left a stale error: " + scenario)
            }
            await notifications.refreshAuthorization()
            notifications.synchronize(host)
            guard service.delivered.count == 1 else { throw DiscoboxError("Permission refresh duplicated a delivered approval") }
            await notifications.sendTestNotification()
            guard service.delivered.last?.identifier == "discobox-notification-test",
                  service.delivered.last?.content.categoryIdentifier == "" else {
                throw DiscoboxError("Test notification accidentally offered approval actions")
            }
        }
        print("NOTIFICATION_PERMISSION_SMOKE_OK: OS denial, request failure, delivery refusal and false authorization result recover on refresh; pending approvals retry once and old errors clear; fake service only")
    }

    private static func waitForNotification(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw DiscoboxError("Notification permission fixture timed out")
    }

    private static func verifyBackgroundNotificationRecovery() async throws {
        let suite = "ai.discobox.smoke.notification-background." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let computers = Connections(polling: false)
        let host = try await computers.connect(.thisComputer, demo: true) { DemoClient(pendingRequests: true) }
        defer { computers.disconnectAll() }
        await host.workspace.refreshApprovals()
        let firstService = NotificationPermissionFixture(), secondService = NotificationPermissionFixture()
        firstService.transientDeliveryError = true
        let first = ApprovalNotifications(service: firstService, defaults: defaults, retryDelay: .milliseconds(20))
        let second = ApprovalNotifications(service: secondService, defaults: defaults)
        first.configure(computers); second.configure(computers)
        try await waitForNotification { first.waitingCount == 1 && secondService.delivered.count == 1 }
        firstService.transientDeliveryError = false
        // No Settings visit, application activation, changed approval or manual
        // refresh is needed to retry a transient enqueue failure.
        try await waitForNotification { firstService.delivered.count == 1 && first.waitingCount == 0 }
        try await Task.sleep(for: .milliseconds(75))
        guard firstService.delivered.count == 1, secondService.delivered.count == 1 else {
            throw DiscoboxError("Notification recovery duplicated an alert or made clients mutually exclusive")
        }
        firstService.alertsEnabled = false; firstService.alertStyle = .none
        await first.refreshAuthorization()
        guard first.bannersDisabled, !first.permissionBlocked else {
            throw DiscoboxError("Authorized notifications with banners disabled were reported as ready")
        }
        await first.setEnabled(false); await second.setEnabled(false)
        defaults.set(true, forKey: ApprovalNotifications.preferenceKey)
        let deniedService = NotificationPermissionFixture()
        deniedService.status = .denied
        let denied = ApprovalNotifications(service: deniedService, defaults: defaults, retryDelay: .milliseconds(20))
        denied.configure(computers)
        try await waitForNotification { denied.waitingCount == 1 }
        deniedService.status = .authorized
        try await waitForNotification { deniedService.delivered.count == 1 && denied.waitingCount == 0 }
        await denied.setEnabled(false)
        print("NOTIFICATION_BACKGROUND_SMOKE_OK: independent clients both alert; transient failures and restored permissions retry without activation; no duplicates; disabled banners are visible in settings")
    }

    private static func verifyAppearance() async throws {
        let saved = NSApp.appearance
        let probe = AppearanceProbe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: AppearanceProbeView(probe: probe))
        window.orderFront(nil)
        defer { window.orderOut(nil); NSApp.appearance = saved }
        for mode in [DiscoboxAppearance.Mode.light, .dark, .system, .dark, .system] {
            DiscoboxAppearance.apply(mode)
            let expected: ColorScheme = mode == .system
                ? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
                : (mode == .dark ? .dark : .light)
            for _ in 0..<100 {
                if probe.scheme == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let nativeDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard nativeDark == (expected == .dark), probe.scheme == expected else {
                throw DiscoboxError("Appearance did not update existing native and SwiftUI windows for \(mode.rawValue)")
            }
            let added = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            let addedDark = added.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard addedDark == (expected == .dark) else { throw DiscoboxError("New window did not inherit appearance") }
            added.orderOut(nil)
            if mode == .system, NSApp.appearance != nil { throw DiscoboxError("System appearance did not remove the app override") }
        }
        print("APPEARANCE_SMOKE_OK: Light, Dark, System; existing SwiftUI/native windows and new windows follow the app setting")
        fflush(stdout)
    }
}

private actor ComputerUsageFixture: DiscoboxClient {
    let demo = DemoClient()
    let percent: Int
    var usageReads = 0
    init(percent: Int) { self.percent = percent }
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .usage { usageReads += 1 }
        if request.operation == .auditBody, request.requestID == "demo-quota" {
            return try JSONSerialization.data(withJSONObject: ["text": "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent),\"limit_window_seconds\":18000}}}", "truncated": false])
        }
        return try await demo.perform(request)
    }
}

@MainActor private final class NotificationPermissionFixture: ApprovalNotificationService {
    var status = UNAuthorizationStatus.authorized
    var granted = true
    var requestError = false
    var deliveryError = false
    var transientDeliveryError = false
    var authorizationRequests = 0
    var delivered: [UNNotificationRequest] = []
    var alertsEnabled = true
    var notificationCenterEnabled = true
    var alertStyle = UNAlertStyle.banner
    func configuration() async -> ApprovalNotificationConfiguration {
        .init(authorization: status, alertsEnabled: alertsEnabled, notificationCenterEnabled: notificationCenterEnabled, alertStyle: alertStyle)
    }
    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if requestError { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
        return granted
    }
    func add(_ request: UNNotificationRequest) async throws {
        if transientDeliveryError { throw NSError(domain: "NotificationFixture", code: 1) }
        if deliveryError { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
        delivered.append(request)
    }
    func remove(_ ids: [String]) { delivered.removeAll { ids.contains($0.identifier) } }
    func removeAll() { delivered.removeAll() }
}

@MainActor private final class AppearanceProbe { var scheme: ColorScheme? }

private actor StudioInboxFixture: DiscoboxClient {
    private let demo = DemoClient()
    func perform(_ request: BridgeRequest) async throws -> Data {
        if request.operation == .tools {
            return Data(#"{"tools":[{"id":"ai.discobox.diff","name":"Changes","description":"Review changes in this box.","runs":"sandbox"},{"id":"fixture-tests","name":"Tests","description":"Open the test console.","runs":"sandbox"}]}"#.utf8)
        }
        if request.operation == .approvals {
            return Data(#"{"approvalRequests":[{"kind":"credential","credential":{"id":"studio-github","sandboxId":"demo-ui","status":"pending","name":"GitHub","justification":"Read repository issues."}},{"kind":"credential","credential":{"id":"studio-notion","sandboxId":"demo-ui","status":"pending","name":"Notion","justification":"Read the project notes."}}]}"#.utf8)
        }
        return try await demo.perform(request)
    }
}

private struct AppearanceProbeView: View {
    @Environment(\.colorScheme) private var scheme
    let probe: AppearanceProbe
    var body: some View { Color.clear.onChange(of: scheme, initial: true) { probe.scheme = scheme } }
}
