import AppKit
import Observation
import DiscoboxCore

/// Local listeners live independently of the activity drawer, so a browser keeps
/// working when the drawer is hidden. Disconnect/stop/app exit release them.
@MainActor @Observable final class ServiceForwards {
    private struct Key: Hashable {
        let connection: UUID
        let project: String
        let box: String
    }
    private var sessions: [Key: ServiceForwardSession] = [:]
    private func key(box: String, workspace: ConnectionSession) -> Key {
        Key(connection: workspace.connectionState.connectionID, project: workspace.connectionState.projectID ?? "", box: box)
    }
    func existingSession(box: String, workspace: ConnectionSession) -> ServiceForwardSession? {
        sessions[key(box: box, workspace: workspace)]
    }
    private var openingLink: Task<Void, Never>?
    func session(box: String, workspace: ConnectionSession) -> ServiceForwardSession {
        let key = key(box: box, workspace: workspace)
        if let session = sessions[key] { return session }
        let session = ServiceForwardSession(endpoint: workspace.connectionState.transportEndpoint, project: workspace.connectionState.projectID ?? "", box: box, demo: workspace.connectionState.isDemo)
        sessions[key] = session
        return session
    }
    func openTerminalURL(_ url: URL, identity: TerminalIdentity, workspace: ConnectionSession, window: NSWindow?) {
        openingLink?.cancel()
        guard !workspace.connectionState.isDemo, workspace.connectionState.connectionID == identity.connection else { return }
        guard ForwardedServiceURL.sandboxPort(url) != nil else { NSWorkspace.shared.open(url); return }
        guard workspace.inventory.sandboxes.contains(where: { $0.id == identity.box && $0.isRunning }),
              !workspace.pending.pendingBoxActions.contains(identity.box) else { return }
        let forward = session(box: identity.box, workspace: workspace)
        openingLink = Task { @MainActor [weak workspace, weak window] in
            for _ in 0..<100 {
                guard forward.loading else { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, let workspace, workspace.connectionState.connectionID == identity.connection else { return }
            if let local = ForwardedServiceURL.resolve(url, ports: forward.ports) {
                NSWorkspace.shared.open(local)
            } else if let window, window.attachedSheet == nil {
                StudioAppKitDialog.message(title: "This box port isn’t forwarded", symbol: "network.slash",
                    message: forward.error ?? "Open Services to check the reported ports for this box. The original localhost address wasn’t opened because it could belong to another app on your Mac.", for: window)
            }
        }
    }

    func close(box: String) {
        for key in Array(sessions.keys) where key.box == box {
            sessions.removeValue(forKey: key)?.close()
        }
    }
    func retainRunningBoxes(_ boxes: [Sandbox]) {
        let running = Set(boxes.filter(\.isRunning).map(\.id))
        for key in Array(sessions.keys) where !running.contains(key.box) { close(box: key.box) }
    }
    func closeAll() { openingLink?.cancel(); openingLink = nil; for session in sessions.values { session.close() }; sessions.removeAll() }
}

@MainActor @Observable final class ServiceForwardSession {
    private(set) var ports: [ServicePort] = []
    private(set) var error: String?
    private(set) var loading = true
    /// The `--forward` child; its stdin EOF also cancels listeners if the app exits.
    @ObservationIgnored private var forwarder: CompanionChild<ServiceForwardSnapshot>?
    @ObservationIgnored private var reports: Task<Void, Never>?
    private var closed = false

    init(endpoint: String, project: String, box: String, demo: Bool) {
        if demo {
            let fixture = #"{"ports":[{"port":6900,"local":6901,"protocol":"http","serviceId":"ai.discobox.desktop","serviceName":"Desktop"},{"port":5173,"local":5173,"protocol":"http","serviceId":"web","serviceName":"Development server"},{"port":5432,"local":5433,"protocol":"tcp","serviceId":"","serviceName":""}]}"#
            do { let snapshot = try JSONDecoder().decode(ServiceForwardSnapshot.self, from: Data(fixture.utf8)); receive(.message(snapshot)) }
            catch { receive(.invalidLine(error.localizedDescription)) }
            return
        }
        let forwarder = CompanionChild<ServiceForwardSnapshot>(executable: CompanionLocation.executable,
            arguments: ["--forward", "--endpoint", endpoint, "--project", project, "--box", box], maxLineBytes: 1024 * 1024)
        self.forwarder = forwarder
        do {
            try forwarder.start()
            let events = forwarder.events
            reports = Task { @MainActor [weak self] in
                for await event in events { self?.receive(event) }
            }
        } catch { self.error = error.localizedDescription; loading = false; close() }
    }
    private func receive(_ event: CompanionChild<ServiceForwardSnapshot>.Event) {
        guard !closed else { return }
        switch event {
        case .message(let snapshot): ports = snapshot.ports; error = snapshot.error; loading = false
        case .invalidLine(let reason): error = "Invalid port report: \(reason)"; loading = false
        case .ended(.lineTooLong): error = "Port report exceeded its size limit."; close()
        case .ended(.exited):
            loading = false; ports = []
            if error == nil { error = "Port forwarding ended. Reconnect ports to try again." }
        }
    }
    func close() {
        closed = true; loading = false; ports = []
        reports?.cancel(); reports = nil
        forwarder?.close()
    }
}
