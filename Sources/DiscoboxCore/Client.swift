import Foundation

public protocol DiscoboxClient: Sendable {
    func perform(_ request: BridgeRequest) async throws -> Data
    func prepareConnection() async throws -> String?
    func closeConnection()
}

extension DiscoboxClient {
    public func prepareConnection() async throws -> String? { nil }
    public func closeConnection() {}
    public func decode<T: Decodable & Sendable>(_ request: BridgeRequest, as type: T.Type) async throws -> T {
        let data = try await perform(request)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DiscoboxError("The server returned an unexpected response: \(error.localizedDescription)") }
    }
}

/// A separate process for each bounded request keeps cancellation independent
/// from the backend. Only an explicit input request opts into the write route.
public actor CompanionClient: DiscoboxClient {
    public nonisolated static func cancelAllRequests() { ProcessRequest.cancelAll() }
    private let executable: URL
    private let endpoint: String
    private nonisolated let remote: IrohConnection?

    public init(executable: URL, endpoint: String, identitySeed: Data? = nil, relayURLs: [String] = [], directOnly: Bool = false) {
        self.executable = executable
        self.endpoint = endpoint
        remote = identitySeed.map { IrohConnection(executable: executable, endpoint: endpoint, seed: $0, relayURLs: relayURLs, directOnly: directOnly) }
    }
    public func prepareConnection() async throws -> String? {
        if let remote { return try await remote.prepare() }
        return endpoint
    }
    public nonisolated func closeConnection() { remote?.close() }

    public func perform(_ request: BridgeRequest) async throws -> Data {
        try await perform(request, progress: nil)
    }
    public func perform(_ request: BridgeRequest, progress: (@Sendable (Int64) -> Void)?) async throws -> Data {
        let destination = try await prepareConnection() ?? endpoint
        let payload = try JSONEncoder().encode(request)
        let job = ProcessRequest(executable: executable, endpoint: destination,
                                 interactive: request.operation == .input, newShell: request.operation == .newShell, manage: (request.operation == .auditBody && request.localPath != nil) || [.deleteSecret, .boxAction, .createBox, .closeShell, .closeTerminal, .answer, .createSecret, .openTool, .newAgent, .upload, .download].contains(request.operation), payload: payload, progress: progress)
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: Task.currentPriority) { try job.run() }.value
        } onCancel: { job.cancel() }
        try Task.checkCancellation()
        let response: BridgeResponse
        do { response = try JSONDecoder().decode(BridgeResponse.self, from: data) }
        catch { throw DiscoboxError("The companion returned an invalid response. Rebuild the app and companion together.") }
        guard response.version == 1 else { throw DiscoboxError("Unsupported companion protocol version.") }
        if let error = response.error, !error.isEmpty { throw DiscoboxError(error) }
        guard (200..<300).contains(response.status) else {
            if response.status == 401 || response.status == 403 {
                throw DiscoboxError("Access refused (\(response.status)). For Iroh, enroll this app’s peer ID on the remote server or check whether it was revoked. Discobot authentication is not supported.")
            }
            let problem = response.body.flatMap { try? JSONDecoder().decode(APIProblem.self, from: $0) }
            let detail = problem?.detail ?? problem?.error ?? problem?.message ?? "The request was refused."
            throw DiscoboxError("HTTP \(response.status): \(detail)")
        }
        return response.body ?? Data()
    }
}

private struct BridgeResponse: Decodable {
    let version: Int
    let status: Int
    let body: Data?
    let error: String?
}
private struct APIProblem: Decodable {
    let detail: String?
    let error: String?
    let message: String?
}

/// Foundation's Process has blocking pipe I/O. It runs off the main actor;
/// the lock protects its launch/cancel race, not UI state.
private final class ProcessRequest: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var jobs: [ObjectIdentifier: ProcessRequest] = [:]
    }
    private static let registry = Registry()
    static func cancelAll() {
        let jobs = registry.lock.withLock { Array(registry.jobs.values) }
        for job in jobs { job.cancel() }
    }
    private let lock = NSLock()
    private var cancelled = false
    private let process = Process()
    private let payload: Data
    private let progress: (@Sendable (Int64) -> Void)?

    init(executable: URL, endpoint: String, interactive: Bool, newShell: Bool, manage: Bool, payload: Data, progress: (@Sendable (Int64) -> Void)? = nil) {
        self.progress = progress
        process.executableURL = executable
        if Task.currentPriority.rawValue <= TaskPriority.utility.rawValue { process.qualityOfService = .utility }
        process.arguments = ["--endpoint", endpoint] + (interactive ? ["--allow-input"] : []) + (newShell ? ["--allow-shell"] : []) + (manage ? ["--allow-manage"] : [])
        self.payload = payload
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    func run() throws -> Data {
        Self.registry.lock.withLock { Self.registry.jobs[ObjectIdentifier(self)] = self }
        defer { _ = Self.registry.lock.withLock { Self.registry.jobs.removeValue(forKey: ObjectIdentifier(self)) } }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let progressPipe = Pipe()
        if let progress {
            let lines = ProgressLines(receive: progress)
            progressPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                lines.append(data)
            }
            process.standardError = progressPipe
        } else { process.standardError = FileHandle.nullDevice }
        defer { progressPipe.fileHandleForReading.readabilityHandler = nil; try? progressPipe.fileHandleForReading.close(); try? progressPipe.fileHandleForWriting.close() }
        defer {
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
        }
        try lock.withLock {
            if cancelled { throw CancellationError() }
            do { try process.run() }
            catch { throw DiscoboxError("Could not launch the companion. Build the app with scripts/build-app.sh. \(error.localizedDescription)") }
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: payload)
            try stdin.fileHandleForWriting.close()
            var output = Data()
            while let chunk = try stdout.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                output.append(chunk)
                guard output.count <= 12 * 1024 * 1024 else {
                    cancel()
                    throw DiscoboxError("Companion response exceeded the size limit.")
                }
            }
            process.waitUntilExit()
            if lock.withLock({ cancelled }) { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw DiscoboxError("The companion exited unexpectedly (\(process.terminationStatus)).") }
            return output
        } catch {
            cancel()
            process.waitUntilExit()
            throw error
        }
    }
}

private final class ProgressLines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let receive: @Sendable (Int64) -> Void
    init(receive: @escaping @Sendable (Int64) -> Void) { self.receive = receive }
    func append(_ data: Data) {
        let values: [Int64] = lock.withLock {
            pending.append(data)
            var values: [Int64] = []
            while let end = pending.firstIndex(of: 10) {
                if let text = String(data: pending[..<end], encoding: .utf8), let value = Int64(text) { values.append(value) }
                pending.removeSubrange(...end)
            }
            if pending.count > 1024 { pending.removeAll() }
            return values
        }
        for value in values { receive(value) }
    }
}
