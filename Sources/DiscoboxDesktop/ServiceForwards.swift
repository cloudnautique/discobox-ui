import AppKit
import Observation
import DiscoboxCore

/// Local listeners live independently of the activity drawer, so a browser keeps
/// working when the drawer is hidden. Disconnect/stop/app exit release them.
@MainActor @Observable final class ServiceForwards {
    private var sessions: [String: ServiceForwardSession] = [:]
    func session(box: String, workspace: Workspace) -> ServiceForwardSession {
        if let session = sessions[box] { return session }
        let session = ServiceForwardSession(endpoint: workspace.transportEndpoint, project: workspace.projectID ?? "", box: box, demo: workspace.isDemo)
        sessions[box] = session
        return session
    }
    func close(box: String) { sessions.removeValue(forKey: box)?.close() }
    func retainRunningBoxes(_ boxes: [Sandbox]) {
        let running = Set(boxes.filter(\.isRunning).map(\.id))
        for box in Array(sessions.keys) where !running.contains(box) { close(box: box) }
    }
    func closeAll() { for session in sessions.values { session.close() }; sessions.removeAll() }
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
