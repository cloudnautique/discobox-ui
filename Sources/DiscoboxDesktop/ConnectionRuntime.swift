import SwiftUI
import DiscoboxCore

@MainActor final class ConnectionRuntime {
    let terminals = TerminalStore()
    let forwards = ServiceForwards()
    let desktops = DesktopWindows()
    func close() { terminals.closeAll(); forwards.closeAll(); desktops.closeAll() }
}
@MainActor @Observable final class ConnectionRuntimes {
    private var hosts: [String: ConnectionRuntime] = [:]
    func runtime(_ id: String) -> ConnectionRuntime {
        if let existing = hosts[id] { return existing }
        let runtime = ConnectionRuntime(); hosts[id] = runtime; return runtime
    }
    func closeAll() { for host in hosts.values { host.close() } }
}

/// Always mounted, including for computers whose workspace is off screen.
struct ConnectionLifecycle: View {
    let connections: Connections
    let session: ConnectionSession
    let runtime: ConnectionRuntime
    var body: some View {
        let workspace = session
        Color.clear.frame(width: 0, height: 0)
            .onAppear { runtime.desktops.computerName = session.profile.displayName }
            .onChange(of: session.profile) { runtime.desktops.computerName = session.profile.displayName }
            .onChange(of: workspace.connectionState.connectionID) { old, _ in
                runtime.close()
                HarnessSetupWindows.shared.close(connection: old)
                ApprovalNotifications.shared.synchronize(session)
                connections.reconcileCreations()
            }
            .onChange(of: workspace.approvalStore.approvals, initial: true) { ApprovalNotifications.shared.synchronize(session) }
            .onChange(of: workspace.connectionState.isConnected) { ApprovalNotifications.shared.synchronize(session) }
            .onChange(of: workspace.connectionState.transportEndpoint) { old, new in
                if !old.isEmpty, old != new { runtime.terminals.closeAll(); runtime.forwards.closeAll() }
            }
            .onChange(of: workspace.inventory.lastRefresh) {
                guard workspace.connectionState.connectionError == nil, workspace.selection.detailError == nil,
                      let inventory = workspace.selection.terminalInventory else { return }
                runtime.terminals.recoverInterrupted(inventory, connection: workspace.connectionState.connectionID)
            }
            .onChange(of: workspace.pending.pendingBoxActions) {
                for box in workspace.pending.pendingBoxActions { runtime.forwards.close(box: box); runtime.desktops.close(box: box) }
            }
            .onChange(of: workspace.selection.terminalInventory) {
                if let inventory = workspace.selection.terminalInventory {
                    runtime.terminals.retainExecs(inventory, connection: workspace.connectionState.connectionID)
                    if workspace.connectionState.connectionError == nil, workspace.selection.detailError == nil {
                        runtime.terminals.recoverInterrupted(inventory, connection: workspace.connectionState.connectionID)
                    }
                }
            }
            .onChange(of: workspace.inventory.sandboxes) {
                runtime.terminals.retainRunningBoxes(workspace.inventory.sandboxes, connection: workspace.connectionState.connectionID)
                runtime.forwards.retainRunningBoxes(workspace.inventory.sandboxes)
                runtime.desktops.retainRunningBoxes(workspace.inventory.sandboxes)
                connections.reconcileCreations()
            }
    }
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
    @State private var notifications = ApprovalNotifications.shared
    @State private var boxActions = BoxActionPresentation()
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
            .background {
                ZStack { ForEach(connections.sessions) { host in ConnectionLifecycle(connections: connections, session: host, runtime: runtimes.runtime(host.id)) } }
            }
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
            .sheet(isPresented: Binding(get: { notifications.actionError != nil }, set: { if !$0 { notifications.actionError = nil } })) {
                StudioMessageSheet(title: "Approval notification", symbol: "bell.badge", message: notifications.actionError ?? "") {
                    notifications.actionError = nil
                }
            }
    }
}
