import SwiftUI
import Network
import DiscoboxCore

struct ConnectionStatusBadge: View {
    let workspace: ConnectionSession
    var compact = false
    private var title: String {
        if workspace.connectionState.isConnecting { return "Connecting…" }
        if workspace.connectionState.recovery.isAttempting { return "Reconnecting…" }
        if workspace.connectionState.connectionError != nil { return workspace.connectionState.recovery.requiresAction ? "Connection issue" : "Retrying…" }
        return workspace.connectionState.isDemo ? "Demo" : workspace.connectionState.isConnected ? "Connected" : "Disconnected"
    }
    var body: some View {
        HStack(spacing: 6) {
            if workspace.connectionState.recovery.isAttempting || workspace.connectionState.isConnecting { ProgressView().controlSize(.mini) }
            else { Circle().fill(workspace.connectionState.isConnected && workspace.connectionState.connectionError == nil ? Color.green : workspace.connectionState.canReconnect ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 5, height: 5) }
            if !compact || workspace.connectionState.connectionError != nil { Text(title).lineLimit(1) }
        }.font(.caption).foregroundStyle(.secondary).help(workspace.connectionState.connectionError ?? title)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityValue(workspace.connectionState.connectionError ?? "")
    }
}

/// Separate from the computer filter: inspecting a failed host must not switch
/// workspaces or hide boxes on other hosts.
struct ComputerConnectionStatus: View {
    let workspace: ConnectionSession
    let computer: String
    let disconnect: () -> Void
    @State private var showingDetails = false

    var body: some View {
        Group {
            if workspace.connectionState.connectionError != nil {
                Button { showingDetails = true } label: {
                    ConnectionStatusBadge(workspace: workspace, compact: true)
                        .padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("Show connection issue for \(computer): \(workspace.connectionState.connectionError ?? "")")
                    .accessibilityLabel("Connection details for \(computer)")
                    .accessibilityIdentifier("computer.connectionDetails")
            } else {
                ConnectionStatusBadge(workspace: workspace, compact: true)
            }
        }.popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 16) {
                StudioDialogHeader(title: "Connection", symbol: "network", subtitle: computer)
                if workspace.connectionState.connectionError != nil {
                    ConnectionRecoveryBanner(workspace: workspace, computer: computer) {
                        showingDetails = false
                        disconnect()
                    }
                } else {
                    Label(workspace.connectionState.isConnected ? "Connected" : "Disconnected", systemImage: workspace.connectionState.isConnected ? "checkmark.circle" : "network.slash")
                    Text("There is no current connection error.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20).frame(width: 520).background(DiscoboxAppearance.surface).tint(DiscoboxAppearance.accent)
        }
    }
}

struct ConnectionRecoveryBanner: View {
    let workspace: ConnectionSession
    let computer: String
    let disconnect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: workspace.connectionState.recovery.requiresAction ? "exclamationmark.triangle" : "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.connectionState.recovery.requiresAction ? "Connection to \(computer) needs attention" : "Reconnecting to \(computer)")
                        .font(.system(size: 12, weight: .medium))
                    if workspace.connectionState.recovery.isAttempting {
                        Text("Checking the host…").font(.caption).foregroundStyle(.secondary)
                    } else if let deadline = workspace.connectionState.recovery.nextRetryAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Trying again in \(max(1, Int(ceil(deadline.timeIntervalSince(context.date))))) seconds. Your last-known boxes stay visible.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Check the connection details or authorization, then retry.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Retry now") { Task { await workspace.retryConnection() } }
                    .disabled(workspace.connectionState.isConnecting || workspace.connectionState.recovery.isAttempting)
                Button("Disconnect", action: disconnect)
            }
            if let error = workspace.connectionState.connectionError {
                ScrollView {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(DiscoboxAppearance.warning.opacity(0.07))
    }
}

/// Network availability is only a hint to probe previously requested hosts.
/// It never opens a saved-but-disconnected computer or loads Keychain again.
@MainActor final class ConnectionReachability {
    static let shared = ConnectionReachability()
    private var monitor: NWPathMonitor?
    func start(_ connections: Connections) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        let availability = PathRecoveryTrigger()
        monitor.pathUpdateHandler = { [weak connections] path in
            guard availability.becameAvailable(path.status == .satisfied) else { return }
            Task { @MainActor in await connections?.retryInterruptedConnections(probeHealthy: true) }
        }
        monitor.start(queue: DispatchQueue(label: "ai.discobox.connection-recovery", qos: .utility))
    }
    func stop() { monitor?.cancel(); monitor = nil }
}

private final class PathRecoveryTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: Bool?
    func becameAvailable(_ available: Bool) -> Bool {
        lock.withLock { defer { previous = available }; return previous == false && available }
    }
}
