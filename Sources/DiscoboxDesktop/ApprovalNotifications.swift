import SwiftUI
import DiscoboxCore
import CryptoKit
@preconcurrency import UserNotifications

/// Install the notification delegate before AppKit finishes launching, including
/// when Notification Center launches the app to deliver an old banner action.
final class DiscoboxApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains(where: { $0.hasSuffix("-smoke") || $0 == "--demo" }) else { return }
        ApprovalNotifications.shared.install()
    }
}

struct NotificationApprovalPresentation: Identifiable {
    let id = UUID()
    let workspace: Workspace
    let item: ApprovalItem
}

@MainActor protocol ApprovalNotificationService: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func remove(_ ids: [String])
    func removeAll()
}

@MainActor private final class SystemApprovalNotificationService: ApprovalNotificationService {
    let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter) { self.center = center }
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func remove(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    func removeAll() { center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications() }
}

@MainActor @Observable final class ApprovalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ApprovalNotifications()
    static let preferenceKey = "approvalNotificationsEnabled"
    private static let directCategory = "discobox.approval.direct"
    private static let reviewCategory = "discobox.approval.review"
    private var center: (any ApprovalNotificationService)?
    private let defaults: UserDefaults
    private var connections: Connections?
    private let inbox = ApprovalNoticeInbox()
    private var deliveryTasks: [String: Task<Void, Never>] = [:]
    private var queuedResponses: [(String, String, String)] = []
    private var permissionTask: Task<Bool, Never>?
    private var requestedThisLaunch = false
    private var waitingForPermission: Set<String> = []
    private var permissionRejected = false
    @ObservationIgnored weak var window: NSWindow?
    private(set) var enabled: Bool
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var checkingPermission = false
    private(set) var deliveryError: String?
    var presentation: NotificationApprovalPresentation?
    var actionError: String?
    var permissionBlocked: Bool { authorization == .denied || permissionRejected }
    var waitingCount: Int { waitingForPermission.count }

    init(service: (any ApprovalNotificationService)? = nil, defaults: UserDefaults = .standard) {
        center = service
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        super.init()
    }

    func install() {
        guard center == nil else { return }
        let center = UNUserNotificationCenter.current()
        self.center = SystemApprovalNotificationService(center: center)
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        // Session-bound banners from a previous run are never executable again.
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    static var categories: Set<UNNotificationCategory> {
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive, .authenticationRequired])
        let later = UNNotificationAction(identifier: "later", title: "Later", options: [])
        return [
            UNNotificationCategory(identifier: Self.directCategory, actions: [
                UNNotificationAction(identifier: "approve", title: "Approve", options: [.authenticationRequired]), deny, later
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.reviewCategory, actions: [
                UNNotificationAction(identifier: "approve", title: "Approve…", options: [.foreground]), deny, later
            ], intentIdentifiers: [], options: [])
        ]
    }

    func configure(_ connections: Connections) {
        guard center != nil else { return }
        self.connections = connections
        for host in connections.sessions { synchronize(host) }
        let queued = queuedResponses; queuedResponses.removeAll()
        for (id, action, computer) in queued { Task { await respond(id: id, action: action, computerID: computer) } }
    }

    func synchronize(_ session: ConnectionSession) {
        guard center != nil, connections != nil, enabled else { return }
        let workspace = session.workspace
        let changes = inbox.update(computerID: session.id, connection: workspace.connectionID,
                                   items: workspace.isConnected ? workspace.approvals : [])
        remove(changes.removed)
        for notice in changes.added { enqueue(notice, session: session) }
    }

    private func enqueue(_ notice: ApprovalNotice, session: ConnectionSession) {
        guard deliveryTasks[notice.id] == nil else { return }
        deliveryTasks[notice.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTasks.removeValue(forKey: notice.id) }
            await self.deliver(notice, session: session)
        }
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        defaults.set(value, forKey: Self.preferenceKey)
        deliveryError = nil
        if !value {
            remove(inbox.reset())
            center?.removeAll()
        } else if await allowDelivery(), enabled {
            for host in connections?.sessions ?? [] { synchronize(host) }
            retryWaiting()
        }
    }

    func refreshAuthorization() async {
        await readAuthorization()
        if canDeliver {
            permissionRejected = false
            deliveryError = nil
            for host in connections?.sessions ?? [] { synchronize(host) }
            retryWaiting()
        }
    }

    func sendTestNotification() async {
        guard await allowDelivery(), enabled, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Discobox notifications are working"
        content.body = "Approval requests from your connected computers will appear here."
        do {
            try await center.add(UNNotificationRequest(identifier: "discobox-notification-test", content: content, trigger: nil))
            deliveryError = nil
        } catch { await readAuthorization(); recordDeliveryError(error) }
    }

    private var canDeliver: Bool { authorization == .authorized || authorization == .provisional }

    private func readAuthorization() async {
        if let center { authorization = await center.authorizationStatus() }
    }

    private func retryWaiting() {
        guard enabled, canDeliver, !permissionRejected, let connections else { return }
        for id in waitingForPermission {
            guard let notice = inbox.notice(id), let session = connections.session(notice.computerID),
                  session.workspace.isConnected, session.workspace.connectionID == notice.connection,
                  session.workspace.approvals.contains(notice.item) else { waitingForPermission.remove(id); continue }
            enqueue(notice, session: session)
        }
    }

    /// One contextual permission request, shared by simultaneous arrivals on
    /// several computers. Denial never prompts again on subsequent polls.
    private func allowDelivery() async -> Bool {
        guard let center, enabled else { return false }
        if let permissionTask { return await permissionTask.value }
        let task = Task { @MainActor in
            self.checkingPermission = true
            defer { self.checkingPermission = false }
            await self.readAuthorization()
            guard self.authorization != .denied else { return false }
            // Register authorization for this launch even if macOS already has
            // a saved grant. Do not discard the API's granted/denied result.
            if !self.requestedThisLaunch || self.authorization == .notDetermined {
                do {
                    let granted = try await center.requestAuthorization()
                    await self.readAuthorization()
                    guard granted else { self.permissionRejected = true; return false }
                    self.requestedThisLaunch = true
                } catch {
                    await self.readAuthorization()
                    self.recordDeliveryError(error)
                    return false
                }
            }
            if self.canDeliver { self.permissionRejected = false; self.deliveryError = nil }
            return self.canDeliver
        }
        permissionTask = task
        let allowed = await task.value
        permissionTask = nil
        return allowed
    }

    private func deliver(_ notice: ApprovalNotice, session: ConnectionSession) async {
        let allowed = await allowDelivery()
        guard enabled, !Task.isCancelled, inbox.notice(notice.id) == notice,
              session.workspace.connectionID == notice.connection else { return }
        guard allowed else { waitingForPermission.insert(notice.id); return }
        let box = session.workspace.sandboxes.first { $0.id == notice.item.boxID }?.displayName ?? "Box"
        let content = Self.content(for: notice, computer: session.profile.displayName, box: box)
        do {
            try await center?.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
            waitingForPermission.remove(notice.id)
            // Removing a resolved request can race the asynchronous OS enqueue.
            if !enabled || Task.isCancelled || inbox.notice(notice.id) != notice { remove([notice.id]) }
        } catch {
            if !Task.isCancelled {
                await readAuthorization()
                guard !Task.isCancelled, inbox.notice(notice.id) == notice else { return }
                recordDeliveryError(error)
                if permissionBlocked { waitingForPermission.insert(notice.id) }
            }
        }
    }

    private func recordDeliveryError(_ error: any Error) {
        let error = error as NSError
        if error.domain == UNErrorDomain && error.code == UNError.Code.notificationsNotAllowed.rawValue {
            permissionRejected = true
            requestedThisLaunch = false
            deliveryError = "macOS is not allowing Discobox notifications. Allow them in System Settings, then return here or choose Check Again."
        } else { deliveryError = error.localizedDescription }
    }

    static func content(for notice: ApprovalNotice, computer: String, box: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Approval needed"
        content.subtitle = String((computer + " · " + box).prefix(180))
        let direct = notice.item.notificationApprovalPayload != nil
        if let seconds = notice.item.notificationApprovalPayload?["grantTTLSeconds"].number {
            let duration = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            content.body = String((notice.item.title + " · " + duration + "\nOpen in Discobox to inspect the request or adjust access.").prefix(300))
        } else {
            content.body = String((notice.item.title + "\nOpen in Discobox to choose the approval details.").prefix(300))
        }
        // No credential values, policies, justifications, addresses, or tokens
        // in the OS payload. Opaque keys resolve to a live in-memory snapshot.
        content.userInfo = ["computer": Self.computerKey(notice.computerID)]
        content.categoryIdentifier = direct ? Self.directCategory : Self.reviewCategory
        content.sound = .default
        return content
    }

    private func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { deliveryTasks.removeValue(forKey: id)?.cancel() }
        waitingForPermission.subtract(ids)
        center?.remove(ids)
    }

    private func respond(id: String, action: String, computerID: String) async {
        guard let connections else { queuedResponses.append((id, action, computerID)); return }
        if action == "later" || action == UNNotificationDismissActionIdentifier { remove([id]); return }
        guard let notice = inbox.claim(id) else {
            if inbox.notice(id) != nil { return } // An action is already running.
            // Never mutate from an old process/session. Open the correct host's
            // current inbox, with an explanation, instead.
            if let host = connections.sessions.first(where: { Self.computerKey($0.id) == computerID }) { connections.activate(host.id) }
            showApp()
            actionError = "This notification is out of date. Open the current approval inbox on its computer."
            return
        }
        defer { inbox.finish(id) }
        guard let host = connections.session(notice.computerID) else { return }
        let selected: ApprovalNotice.Action
        switch action {
        case "approve": selected = .approve
        case "deny": selected = .deny
        case UNNotificationDefaultActionIdentifier: selected = .open
        default: return
        }
        do {
            let answered = try await notice.respond(selected, workspace: host.workspace)
            if answered { remove([id]) }
            else {
                connections.activate(host.id)
                showApp()
                presentation = .init(workspace: host.workspace, item: notice.item)
            }
        } catch {
            showApp()
            actionError = error.localizedDescription
        }
    }

    private func showApp() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func computerKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { enabled ? [.banner, .list, .sound] : [] }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let computer = response.notification.request.content.userInfo["computer"] as? String ?? ""
        await respond(id: id, action: action, computerID: computer)
    }
}

struct ApprovalNotificationSettings: View {
    @State private var notifications: ApprovalNotifications
    init(notifications: ApprovalNotifications = .shared) { _notifications = State(initialValue: notifications) }
    var body: some View {
        Form {
            Section("Approvals") {
                Toggle(isOn: Binding(get: { notifications.enabled }, set: { value in
                    Task { await notifications.setEnabled(value) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Approval notifications")
                        Text("Get alerts from all connected computers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).padding(.vertical, 4)
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: statusSymbol)
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(notifications.permissionBlocked ? Color.orange : .secondary)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusTitle).fontWeight(.medium)
                            Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        if notifications.checkingPermission {
                            ProgressView().controlSize(.small)
                        } else if notifications.enabled {
                            if notifications.authorization == .notDetermined {
                                Button("Allow…") { Task { await notifications.setEnabled(true) } }
                                    .buttonStyle(.borderedProminent)
                            } else if notifications.permissionBlocked {
                                Button("Open Settings…", action: openSystemSettings)
                                    .buttonStyle(.bordered)
                            } else {
                                Button("Test Notification") { Task { await notifications.sendTestNotification() } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    HStack(spacing: 14) {
                        if !notifications.permissionBlocked || notifications.authorization == .notDetermined {
                            Button(action: openSystemSettings) {
                                HStack(spacing: 4) { Text("Notification settings"); Image(systemName: "arrow.up.right").imageScale(.small) }
                            }
                        }
                        if notifications.permissionBlocked {
                            Button("Check Again") { Task { await notifications.refreshAuthorization() } }
                                .disabled(notifications.checkingPermission)
                        }
                    }
                    .buttonStyle(.link).font(.caption).padding(.leading, 38)
                    if let error = notifications.deliveryError, !notifications.permissionBlocked {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.leading, 38)
                    }
                }.padding(.vertical, 6)
            } footer: {
                Text("Approve or deny from the notification. Later keeps the request pending. Discobox must be running.")
            }
        }.formStyle(.grouped)
            .task { await notifications.refreshAuthorization() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                Task { await notifications.refreshAuthorization() }
            }
    }

    private var statusSymbol: String {
        if !notifications.enabled || notifications.permissionBlocked { return "bell.slash" }
        return notifications.authorization == .notDetermined ? "bell.badge" : "checkmark.circle"
    }
    private var statusTitle: String {
        if !notifications.enabled { return "Notifications paused" }
        if notifications.permissionBlocked { return "Permission needed" }
        if notifications.authorization == .notDetermined { return "Allow notifications" }
        return notifications.authorization == .provisional ? "Delivered quietly" : "Ready to notify"
    }
    private var statusDetail: String {
        if !notifications.enabled { return "Turn on approval notifications to receive alerts." }
        if notifications.permissionBlocked {
            let waiting = notifications.waitingCount
            return waiting > 0
                ? "Allow Discobox in macOS settings. \(waiting) \(waiting == 1 ? "request is" : "requests are") waiting."
                : "Allow Discobox in macOS notification settings."
        }
        if notifications.authorization == .notDetermined { return "macOS needs your permission to show alerts." }
        return "Banner style and sounds follow your macOS settings."
    }
    private func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
