import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol DiscoboxClient: Sendable {
    func perform(_ request: BridgeRequest) async throws -> Data
    func prepareConnection() async throws -> String?
    func closeConnection()
    /// A new connection generation begins with this client (connect or
    /// reconnect). Transport scoped to the previous generation, such as the
    /// persistent read companion, ends so none of its replies cross over.
    func startGeneration()
}

extension DiscoboxClient {
    public func prepareConnection() async throws -> String? { nil }
    public func closeConnection() {}
    public func startGeneration() {}
    public func decode<T: Decodable & Sendable>(_ request: BridgeRequest, as type: T.Type) async throws -> T {
        let data = try await perform(request)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DiscoboxError("The server returned an unexpected response: \(error.localizedDescription)") }
    }
}

/// Read operations share one persistent, read-only companion per connection
/// generation (`ReadCompanion`), so routine polling reuses one process and its
/// HTTP connections. Every other request gets a separate process, which keeps
/// its cancellation independent from the backend and passes only its own
/// permission flag; no long-lived helper ever holds a write permission.
public actor CompanionClient: DiscoboxClient {
    public nonisolated static func cancelAllRequests() { ProcessRequest.cancelAll(); ReadCompanion.closeAll() }
    private let executable: URL
    private let endpoint: String
    private nonisolated let remote: IrohConnection?
    private nonisolated let reads: ReadCompanionSlot?
    private let approvalTimeout: TimeInterval

    public init(executable: URL, endpoint: String, identitySeed: Data? = nil, relayURLs: [String] = [], directOnly: Bool = false) {
        self.init(executable: executable, endpoint: endpoint, approvalTimeout: 25, persistentReads: true,
                  remote: identitySeed.map { IrohConnection(executable: executable, endpoint: endpoint, seed: $0, relayURLs: relayURLs, directOnly: directOnly) })
    }
    // Short deadlines let offline tests exercise a truly unresponsive helper.
    init(executable: URL, endpoint: String, approvalTimeout: TimeInterval) {
        self.init(executable: executable, endpoint: endpoint, approvalTimeout: approvalTimeout, persistentReads: true, remote: nil)
    }
    // Tests of the one-shot path for reads.
    init(executable: URL, endpoint: String, persistentReads: Bool) {
        self.init(executable: executable, endpoint: endpoint, approvalTimeout: 25, persistentReads: persistentReads, remote: nil)
    }
    private init(executable: URL, endpoint: String, approvalTimeout: TimeInterval, persistentReads: Bool, remote: IrohConnection?) {
        self.executable = executable; self.endpoint = endpoint
        self.approvalTimeout = approvalTimeout; self.remote = remote
        reads = persistentReads ? ReadCompanionSlot(executable: executable) : nil
    }
    /// Exactly the operations the companion's read server accepts.
    static func usesReadCompanion(_ operation: BridgeRequest.Operation) -> Bool { operation.permission == .read }
    public func prepareConnection() async throws -> String? {
        if let remote { return try await remote.prepare() }
        return endpoint
    }
    public nonisolated func closeConnection() { reads?.retire(reopen: false); remote?.close() }
    public nonisolated func startGeneration() { reads?.retire(reopen: true) }

    public func perform(_ request: BridgeRequest) async throws -> Data {
        try await perform(request, progress: nil)
    }
    public func perform(_ request: BridgeRequest, progress: (@Sendable (Int64) -> Void)?) async throws -> Data {
        let destination = try await prepareConnection() ?? endpoint
        let payload = try JSONEncoder().encode(request)
        let isApproval = [.approvalContext, .approvals, .secrets, .answer, .createSecret].contains(request.operation)
        let writesApproval = [.answer, .createSecret].contains(request.operation)
        let timeoutMessage = request.operation == .serverPeer ? "The computer did not report its identity in time." : writesApproval
            ? "The remote approval operation timed out. It may have been recorded. Reload the request and check stored credentials before trying again. Nothing was retried."
            : "Checking approvals timed out. The computer may be unreachable. Reload to try again; no decision was sent."
        let deadline: TimeInterval? = request.operation == .serverPeer ? 5 : (isApproval ? approvalTimeout : nil)
        if Self.usesReadCompanion(request.operation), progress == nil, payload.count <= ReadCompanion.maxRequest,
           let companion = reads?.companion(for: destination) {
            // A timed-out read is cancelled in the companion; other reads and
            // the shared transport continue.
            let reply = try await companion.perform(request, timeout: deadline.map { ($0, DiscoboxError(timeoutMessage, connectionRetryable: true)) })
            try Task.checkCancellation()
            return try Self.result(status: reply.status, body: reply.body, error: reply.error, errorKind: reply.errorKind)
        }
        let job = ProcessRequest(executable: executable, endpoint: destination, timeout: deadline, timeoutMessage: timeoutMessage,
                                 permission: request.operation.permission, payload: payload, progress: progress)
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await BlockingThread.run(name: "Discobox companion request") { try job.run() }
        } onCancel: { job.cancel() }
        try Task.checkCancellation()
        let response: BridgeResponse
        do { response = try JSONDecoder().decode(BridgeResponse.self, from: data) }
        catch { throw DiscoboxError("The companion returned an invalid response. Rebuild the app and companion together.") }
        guard response.version == BridgeRequest.protocolVersion else { throw DiscoboxError("Unsupported companion protocol version. Rebuild the app and companion together.") }
        return try Self.result(status: response.status, body: response.body, error: response.error, errorKind: response.errorKind)
    }

    /// One interpretation of a reply for both paths, so error kinds and
    /// messages cannot drift between them.
    private static func result(status: Int, body: Data?, error: String?, errorKind: String?) throws -> Data {
        if let error, !error.isEmpty { throw DiscoboxError(error, kind: .init(wire: errorKind)) }
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 {
                throw DiscoboxError("Access refused (\(status)). For Iroh, enroll this app’s peer ID on the remote server or check whether it was revoked. Discobot authentication is not supported.", kind: .unauthorized)
            }
            let problem = body.flatMap { try? JSONDecoder().decode(APIProblem.self, from: $0) }
            let detail = problem?.detail ?? problem?.error ?? problem?.message ?? "The request was refused."
            throw DiscoboxError("HTTP \(status): \(detail)", connectionRetryable: [408, 425, 429, 500, 502, 503, 504].contains(status))
        }
        return body ?? Data()
    }
}

private struct BridgeResponse: Decodable {
    let version: Int
    let status: Int
    let body: Data?
    let error: String?
    let errorKind: String?
}
private struct APIProblem: Decodable {
    let detail: String?
    let error: String?
    let message: String?
}

/// Foundation's Process has blocking pipe I/O. `run()` executes on a
/// dedicated `BlockingThread`, never the cooperative pool; the lock protects
/// its launch/cancel race, not UI state.
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
    private var timedOut = false
    private let timeout: TimeInterval?
    private let timeoutMessage: String
    private let process = Process()
    private let payload: Data
    private let progress: (@Sendable (Int64) -> Void)?

    init(executable: URL, endpoint: String, timeout: TimeInterval?, timeoutMessage: String, permission: BridgeRequest.Operation.Permission, payload: Data, progress: (@Sendable (Int64) -> Void)? = nil) {
        self.progress = progress
        self.timeout = timeout; self.timeoutMessage = timeoutMessage
        process.executableURL = executable
        if Task.currentPriority.rawValue <= TaskPriority.utility.rawValue { process.qualityOfService = .utility }
        let flag: [String] = switch permission {
        case .read: []
        case .manage: ["--allow-manage"]
        case .shell: ["--allow-shell"]
        }
        process.arguments = ["--endpoint", endpoint] + flag
        self.payload = payload
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    private func expire() {
        lock.withLock {
            guard process.isRunning, !cancelled else { return }
            timedOut = true
            process.terminate()
        }
        // A stuck helper can also ignore SIGTERM. Kill only this request's
        // child, never the shared Iroh transport or the remote server.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if self.timedOut && self.process.isRunning { _ = kill(self.process.processIdentifier, SIGKILL) }
            }
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
        let deadline = DispatchWorkItem { [weak self] in self?.expire() }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline) }
        defer { deadline.cancel() }
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
            if lock.withLock({ timedOut }) { throw DiscoboxError(timeoutMessage, connectionRetryable: true) }
            if lock.withLock({ cancelled }) { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw DiscoboxError("The companion exited unexpectedly (\(process.terminationStatus)).", connectionRetryable: true) }
            return output
        } catch {
            cancel()
            process.waitUntilExit()
            if lock.withLock({ timedOut }) { throw DiscoboxError(timeoutMessage, connectionRetryable: true) }
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
