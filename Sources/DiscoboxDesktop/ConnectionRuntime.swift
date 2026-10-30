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
    let session: ConnectionSession
    let runtime: ConnectionRuntime
    var body: some View {
        let workspace = session.workspace
        Color.clear.frame(width: 0, height: 0)
            .onAppear { runtime.desktops.computerName = session.profile.displayName }
            .onChange(of: session.profile) { runtime.desktops.computerName = session.profile.displayName }
            .onChange(of: workspace.connectionID) { old, _ in
                runtime.close()
                HarnessSetupWindows.shared.close(connection: old)
                ApprovalNotifications.shared.synchronize(session)
            }
            .onChange(of: workspace.approvals, initial: true) { ApprovalNotifications.shared.synchronize(session) }
            .onChange(of: workspace.isConnected) { ApprovalNotifications.shared.synchronize(session) }
            .onChange(of: workspace.pendingBoxActions) {
                for box in workspace.pendingBoxActions { runtime.forwards.close(box: box); runtime.desktops.close(box: box) }
            }
            .onChange(of: workspace.terminalInventory) {
                if let inventory = workspace.terminalInventory { runtime.terminals.retainExecs(inventory, connection: workspace.connectionID) }
            }
            .onChange(of: workspace.sandboxes) {
                runtime.terminals.retainRunningBoxes(workspace.sandboxes, connection: workspace.connectionID)
                runtime.forwards.retainRunningBoxes(workspace.sandboxes)
                runtime.desktops.retainRunningBoxes(workspace.sandboxes)
            }
    }
}

struct ComputerPicker: View {
    @Environment(Connections.self) private var connections: Connections?
    var body: some View {
        if let connections {
            Picker("Computer", selection: Binding(get: { connections.activeID }, set: { connections.activate($0) })) {
                ForEach(connections.sessions) { host in Text(host.profile.displayName).tag(host.id) }
            }
        }
    }
}

struct ConnectedWorkspace: View {
    let connections: Connections
    let runtimes: ConnectionRuntimes
    let commands: WorkspaceCommands
    @State private var notifications = ApprovalNotifications.shared
    private var workspace: Workspace { connections.active.workspace }
    var body: some View {
        let runtime = runtimes.runtime(connections.activeID)
        WorkspaceView()
            .id(connections.activeID)
            .environment(connections)
            .environment(runtimes)
            .environment(workspace)
            .environment(runtime.terminals)
            .environment(runtime.forwards)
            .environment(runtime.desktops)
            .environment(commands)
            .tint(DiscoboxAppearance.accent)
            .background {
                ZStack { ForEach(connections.sessions) { host in ConnectionLifecycle(session: host, runtime: runtimes.runtime(host.id)) } }
            }
            .onChange(of: connections.activeID, initial: true) {
                commands.restoreAgentLayout(); commands.cancelPrefix()
                commands.install(workspace: workspace, connections: connections)
            }
            .onChange(of: workspace.sandboxID) { commands.restoreAgentLayout(); commands.cancelPrefix(); commands.tab = .terminal }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commands.cancelPrefix() }
            .sheet(item: $notifications.presentation) { target in
                ApprovalSheet(item: target.item).environment(target.workspace).environment(connections)
            }
            .alert("Approval notification", isPresented: Binding(get: { notifications.actionError != nil }, set: { if !$0 { notifications.actionError = nil } })) {
                Button("OK") { notifications.actionError = nil }
            } message: { Text(notifications.actionError ?? "") }
    }
}
