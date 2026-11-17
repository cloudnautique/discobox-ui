import SwiftUI
import DiscoboxCore

@MainActor final class ConnectionRuntime {
    let terminals = TerminalStore()
    let forwards = ServiceForwards()
    let desktops = DesktopWindows()
    func close() { terminals.closeAll(); forwards.closeAll(); desktops.closeAll() }

    /// Releases this computer's native resources as its session reports
    /// transitions (see ConnectionLifecycleEvent). Registered once, so it works
    /// whether or not any view of this computer is mounted.
    func follow(_ session: ConnectionSession, connections: Connections) {
        desktops.computerName = session.profile.displayName
        ApprovalNotifications.shared.synchronize(session)
        session.observeLifecycle { [weak self, weak session, weak connections] event in
            guard let self, let session, let connections else { return }
            self.handle(event, session: session, connections: connections)
        }
    }
    private func handle(_ event: ConnectionLifecycleEvent, session: ConnectionSession, connections: Connections) {
        let connection = session.connectionState.connectionID
        switch event {
        case .profileChanged:
            desktops.computerName = session.profile.displayName
        case .generationEnded(let previous):
            close()
            HarnessSetupWindows.shared.close(connection: previous)
            ApprovalNotifications.shared.synchronize(session)
            connections.reconcileCreations()
        case .connectivityChanged, .approvalsChanged:
            ApprovalNotifications.shared.synchronize(session)
        case .transportReplaced:
            terminals.closeAll(); forwards.closeAll()
        case .boxActionsBegan(let boxes):
            for box in boxes { forwards.close(box: box); desktops.close(box: box) }
        case .boxesChanged:
            let boxes = session.inventory.sandboxes
            terminals.retainRunningBoxes(boxes, connection: connection)
            forwards.retainRunningBoxes(boxes)
            desktops.retainRunningBoxes(boxes)
            connections.reconcileCreations()
        case .terminalInventoryChanged(let inventory):
            terminals.retainExecs(inventory, connection: connection)
            recoverTerminals(inventory, session: session)
        case .inventoryRefreshed:
            if let inventory = session.selection.terminalInventory { recoverTerminals(inventory, session: session) }
        }
    }
    private func recoverTerminals(_ inventory: BoxSelectionStore.TerminalInventory, session: ConnectionSession) {
        guard session.connectionState.connectionError == nil, session.selection.detailError == nil else { return }
        terminals.recoverInterrupted(inventory, connection: session.connectionState.connectionID)
    }
}
@MainActor @Observable final class ConnectionRuntimes {
    private var hosts: [String: ConnectionRuntime] = [:]
    @ObservationIgnored private weak var connections: Connections?
    @ObservationIgnored private var followed: Set<ObjectIdentifier> = []
    func runtime(_ id: String) -> ConnectionRuntime {
        if let existing = hosts[id] { return existing }
        let runtime = ConnectionRuntime(); hosts[id] = runtime; return runtime
    }
    /// Idempotent. Every computer of `connections`, including ones added
    /// later, gets its runtime and lifecycle subscription at once rather than
    /// when a view first renders it.
    func attach(_ connections: Connections) {
        guard self.connections !== connections else { return }
        self.connections = connections
        followSessions()
    }
    private func followSessions() {
        guard let connections else { return }
        let sessions = withObservationTracking { connections.sessions } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followSessions() }
        }
        for session in sessions where !followed.contains(ObjectIdentifier(session)) {
            followed.insert(ObjectIdentifier(session))
            runtime(session.id).follow(session, connections: connections)
        }
    }
    func closeAll() { for host in hosts.values { host.close() } }
}

struct ComputerPicker: View {
    @Environment(Connections.self) private var connections: Connections?
    var body: some View {
        if let connections {
            StudioMenuField(title: "Computer", selection: Binding(get: { connections.activeID }, set: { connections.activate($0) }), options:
                connections.sessions.map { .init(id: $0.id, title: $0.profile.displayName) })
        }
    }
}

struct ConnectedWorkspace: View {
    let connections: Connections
    let runtimes: ConnectionRuntimes
    let commands: WorkspaceCommands
    @MainActor init(connections: Connections, runtimes: ConnectionRuntimes, commands: WorkspaceCommands) {
        self.connections = connections; self.runtimes = runtimes; self.commands = commands
        // Lifecycle subscriptions belong to the runtimes, not to this view.
        runtimes.attach(connections)
    }
    @State private var notifications = ApprovalNotifications.shared
    @State private var boxActions = BoxActionPresentation()
    @State private var inbox = ApprovalInboxPresentation()
    private var workspace: ConnectionSession { connections.active }
    var body: some View {
        let runtime = runtimes.runtime(connections.activeID)
        WorkspaceView()
            // Keep the shared List and its native swipe controls alive when
            // selection activates another computer. Detail panes own their IDs.
            .environment(connections)
            .environment(boxActions)
            .environment(runtimes)
            .environment(workspace)
            .environment(runtime.terminals)
            .environment(runtime.forwards)
            .environment(runtime.desktops)
            .environment(commands)
            .tint(DiscoboxAppearance.accent)
            .onChange(of: connections.activeID, initial: true) { old, new in
                if old != new {
                    commands.showTools = false
                    commands.showApprovals = false
                }
                commands.restoreAgentLayout(); commands.cancelPrefix()
                commands.install(workspace: workspace, connections: connections)
            }
            .onChange(of: workspace.selection.sandboxID) { commands.restoreAgentLayout(); commands.cancelPrefix(); commands.tab = .terminal }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commands.cancelPrefix() }
            .modifier(PollingPresenceReporter(connections: connections, commands: commands))
            .modifier(ApprovalInboxHost(presentation: inbox, connections: connections))
            .onChange(of: commands.showApprovals, initial: true) {
                // The command opens the active computer's inbox in the one owner.
                guard commands.showApprovals else { return }
                commands.showApprovals = false
                inbox.present(on: workspace)
            }
            .sheet(item: $boxActions.request) { target in
                let runtime = runtimes.runtime(target.host.id)
                BoxActionSheet(request: .init(box: target.box, action: target.action, connection: target.connection))
                    .environment(target.host)
                    .environment(connections)
                    .environment(runtime.terminals)
                    .environment(runtime.forwards)
                    .environment(runtime.desktops)
                    .id(target.id)
            }
            .sheet(item: $notifications.presentation) { target in
                ApprovalSheet(item: target.item).environment(target.workspace).environment(connections)
            }
            .alert("Approval notification", isPresented: Binding(get: { notifications.actionError != nil }, set: { if !$0 { notifications.actionError = nil } })) {
                Button("OK", role: .cancel) { notifications.actionError = nil }
            } message: { Text(notifications.actionError ?? "") }
    }
}

/// Polling cadence follows what can be seen. A workspace window not yet read
/// counts as on screen, so a missed notification never slows a visible host.
@MainActor private struct PollingPresenceReporter: ViewModifier {
    let connections: Connections
    let commands: WorkspaceCommands
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { report() }
            .onDisappear { connections.withdrawPresence(from: id) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in report() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in report() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in report() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in report() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in report() }
    }
    private func report() {
        let onScreen = commands.window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? true
        connections.reportPresence(!onScreen ? .hidden : NSApp.isActive ? .focused : .visible, from: id)
    }
}
