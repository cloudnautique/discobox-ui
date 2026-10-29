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
    private func key(box: String, workspace: Workspace) -> Key {
        Key(connection: workspace.connectionID, project: workspace.projectID ?? "", box: box)
    }
    func existingSession(box: String, workspace: Workspace) -> ServiceForwardSession? {
        sessions[key(box: box, workspace: workspace)]
    }
    private var openingLink: Task<Void, Never>?
    func session(box: String, workspace: Workspace) -> ServiceForwardSession {
        let key = key(box: box, workspace: workspace)
        if let session = sessions[key] { return session }
        let session = ServiceForwardSession(endpoint: workspace.transportEndpoint, project: workspace.projectID ?? "", box: box, demo: workspace.isDemo)
        sessions[key] = session
        return session
    }
    func openTerminalURL(_ url: URL, identity: TerminalIdentity, workspace: Workspace, window: NSWindow?) {
        openingLink?.cancel()
        guard !workspace.isDemo, workspace.connectionID == identity.connection else { return }
        guard ForwardedServiceURL.sandboxPort(url) != nil else { NSWorkspace.shared.open(url); return }
        guard workspace.sandboxes.contains(where: { $0.id == identity.box && $0.isRunning }),
              !workspace.pendingBoxActions.contains(identity.box) else { return }
        let forward = session(box: identity.box, workspace: workspace)
        openingLink = Task { @MainActor [weak workspace, weak window] in
            for _ in 0..<100 {
                guard forward.loading else { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, let workspace, workspace.connectionID == identity.connection else { return }
            if let local = ForwardedServiceURL.resolve(url, ports: forward.ports) {
                NSWorkspace.shared.open(local)
            } else if let window, window.attachedSheet == nil {
                let alert = NSAlert()
                alert.messageText = "This box port isn’t forwarded"
                alert.informativeText = forward.error ?? "Open Services to check the reported ports for this box. The original localhost address wasn’t opened because it could belong to another app on your Mac."
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window, completionHandler: { _ in })
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
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending = Data()
    private var closed = false

    init(endpoint: String, project: String, box: String, demo: Bool) {
        if demo {
            receive(Data(#"{"ports":[{"port":6900,"local":6901,"protocol":"http","serviceId":"ai.discobox.desktop","serviceName":"Desktop"},{"port":5173,"local":5173,"protocol":"http","serviceId":"web","serviceName":"Development server"},{"port":5432,"local":5433,"protocol":"tcp","serviceId":"","serviceName":""}]}"#.utf8) + Data([10]))
            return
        }
        process.executableURL = CompanionLocation.executable
        process.arguments = ["--forward", "--endpoint", endpoint, "--project", project, "--box", box]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if data.isEmpty {
                    self.loading = false; self.ports = []
                    if self.error == nil { self.error = "Port forwarding ended. Reconnect ports to try again." }
                } else { self.receive(data) }
            }
        }
        do { try process.run() }
        catch { self.error = error.localizedDescription; loading = false; close() }
    }
    private func receive(_ data: Data) {
        pending.append(data)
        guard pending.count <= 1024 * 1024 else { error = "Port report exceeded its size limit."; close(); return }
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            do {
                let snapshot = try JSONDecoder().decode(ServiceForwardSnapshot.self, from: line)
                ports = snapshot.ports; error = snapshot.error; loading = false
            } catch { self.error = "Invalid port report: \(error.localizedDescription)"; loading = false }
        }
    }
    func close() {
        closed = true; loading = false; ports = []
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }
}
