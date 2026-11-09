import SwiftUI
import Network
import DiscoboxCore

struct ConnectionStatusBadge: View {
    let workspace: Workspace
    var compact = false
    private var title: String {
        if workspace.isConnecting { return "Connecting…" }
        if workspace.recovery.isAttempting { return "Reconnecting…" }
        if workspace.connectionError != nil { return workspace.recovery.requiresAction ? "Needs attention" : "Retrying…" }
        return workspace.isDemo ? "Demo" : workspace.isConnected ? "Connected" : "Disconnected"
    }
    var body: some View {
        HStack(spacing: 6) {
            if workspace.recovery.isAttempting || workspace.isConnecting { ProgressView().controlSize(.mini) }
            else { Circle().fill(workspace.isConnected && workspace.connectionError == nil ? Color.green : workspace.canReconnect ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 5, height: 5) }
            if !compact || workspace.connectionError != nil { Text(title).lineLimit(1) }
        }.font(.caption).foregroundStyle(.secondary).help(workspace.connectionError ?? title)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
}

struct ConnectionRecoveryBanner: View {
    let workspace: Workspace
    let computer: String
    let disconnect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: workspace.recovery.requiresAction ? "exclamationmark.triangle" : "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.recovery.requiresAction ? "Connection to \(computer) needs attention" : "Reconnecting to \(computer)")
                        .font(.system(size: 12, weight: .medium))
                    if workspace.recovery.isAttempting {
                        Text("Checking the host…").font(.caption).foregroundStyle(.secondary)
                    } else if let deadline = workspace.recovery.nextRetryAt {
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
                    .disabled(workspace.isConnecting || workspace.recovery.isAttempting)
                Button("Disconnect", action: disconnect)
            }
            if let error = workspace.connectionError {
                DisclosureGroup("Details") { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 4) }
                    .font(.caption)
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
