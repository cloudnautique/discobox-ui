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
            try await verifyNotifications()
            try await verifyNotificationPermissionRecovery()
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
            let panels: [(String, AnyView)] = [
                ("studio-light", AnyView(ConnectedWorkspace(connections: computers, runtimes: computerResources, commands: WorkspaceCommands(defaults: settingsDefaults)).defaultAppStorage(settingsDefaults).preferredColorScheme(.light))),
                ("studio-dark", AnyView(ConnectedWorkspace(connections: computers, runtimes: computerResources, commands: WorkspaceCommands(defaults: settingsDefaults)).defaultAppStorage(settingsDefaults).preferredColorScheme(.dark))),
                ("shell-close", AnyView(TerminalCloseSheet(request: .init(terminal: shell, box: box.id, connection: workspace.connectionID), confirm: {}).defaultAppStorage(settingsDefaults))),
                ("appearance", AnyView(AppearanceSettings().defaultAppStorage(settingsDefaults).frame(width: 640, height: 680))),
                ("notifications", AnyView(ApprovalNotificationSettings().frame(width: 640, height: 680))),
                ("resources", AnyView(PoolResourcesView(computer: "Fixture computer").environment(workspace))),
                ("cache-clear", AnyView(PoolCacheClearSheet(request: .init(pool: resourcePool, connection: workspace.connectionID), computer: "Fixture computer").environment(workspace))),
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
            try await workspace.answer(item, action: "approve", payload: .object(["grantTTLSeconds": .number(900)]))
            guard workspace.approvals.isEmpty else { throw DiscoboxError("Answer did not clear fixture inbox") }
            print("FEATURE_SMOKE_OK: pool resources, cache confirmation, box rows, lifecycle confirmations, approval, new-box preflight, tools and file panel layout; fixture answer clears inbox")
            fflush(stdout); exit(0)
        } catch { print("FEATURE_SMOKE_FAILED: \(error)"); fflush(stdout); exit(1) }
    }

    private static func verifyNotifications() async throws {
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

@MainActor private final class NotificationPermissionFixture: ApprovalNotificationService {
    var status = UNAuthorizationStatus.authorized
    var granted = true
    var requestError = false
    var deliveryError = false
    var authorizationRequests = 0
    var delivered: [UNNotificationRequest] = []
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if requestError { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
        return granted
    }
    func add(_ request: UNNotificationRequest) async throws {
        if deliveryError { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
        delivered.append(request)
    }
    func remove(_ ids: [String]) { delivered.removeAll { ids.contains($0.identifier) } }
    func removeAll() { delivered.removeAll() }
}

@MainActor private final class AppearanceProbe { var scheme: ColorScheme? }
private struct AppearanceProbeView: View {
    @Environment(\.colorScheme) private var scheme
    let probe: AppearanceProbe
    var body: some View { Color.clear.onChange(of: scheme, initial: true) { probe.scheme = scheme } }
}
