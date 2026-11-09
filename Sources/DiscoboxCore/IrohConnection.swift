import Foundation

/// One persistent transport process. Requests and PTYs keep their existing
/// cancellation boundaries and use this process's private Unix socket.
public actor IrohConnection {
    public struct Ready: Decodable, Sendable {
        public let endpoint: String?
        public let peerID: String?
        public let error: String?
        public let errorKind: String?
    }
    private nonisolated let slot = IrohProcessSlot()
    private let makeProcess: @Sendable () -> IrohProcess
    private var startup: (id: UUID, task: Task<Ready, Error>)?
    private var established = false

    public init(executable: URL, endpoint: String, seed: Data, relayURLs: [String] = [], directOnly: Bool = false) {
        makeProcess = { IrohProcess(executable: executable, arguments: ["--iroh-proxy", "--endpoint", endpoint], seed: seed, relayURLs: relayURLs, directOnly: directOnly) }
    }
    public func prepare() async throws -> String {
        guard !slot.isClosed else { throw DiscoboxError("The remote connection helper stopped.") }
        if established && !slot.isRunning {
            startup = nil; established = false; slot.retire()
        }
        if startup == nil {
            let process = makeProcess()
            guard slot.install(process) else { throw CancellationError() }
            startup = (UUID(), Task.detached { try process.start() })
        }
        let attempt = startup!
        do {
            let ready = try await attempt.task.value
            guard !slot.isClosed else { throw DiscoboxError("The remote connection helper stopped.") }
            guard let endpoint = ready.endpoint, endpoint.hasPrefix("unix:///"), slot.isRunning else {
                throw DiscoboxError("The remote connection helper stopped unexpectedly. Retrying can restart it.", connectionRetryable: true)
            }
            guard startup?.id == attempt.id else { throw CancellationError() }
            established = true
            return endpoint
        } catch {
            if startup?.id == attempt.id {
                startup = nil; established = false; slot.retire()
            }
            throw error
        }
    }
    public nonisolated func close() { slot.close() }
    deinit { slot.close() }

    public static func peerID(executable: URL, seed: Data) async throws -> String {
        let process = IrohProcess(executable: executable, arguments: ["--iroh-identity"], seed: seed, relayURLs: [], directOnly: false)
        defer { process.close() }
        return try await withTaskCancellationHandler {
            let ready = try await Task.detached { try process.start() }.value
            guard let id = ready.peerID, id.hasPrefix("d1-") else { throw DiscoboxError("The companion returned an invalid peer ID.") }
            return id
        } onCancel: { process.close() }
    }
}

/// close() can interrupt a pending startup without waiting for the actor. An
/// explicitly closed connection never creates another helper.
private final class IrohProcessSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var process: IrohProcess?
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    var isRunning: Bool { lock.withLock { process?.isRunning == true } }
    func install(_ value: IrohProcess) -> Bool {
        let accepted = lock.withLock { if closed { return false }; process = value; return true }
        if !accepted { value.close() }
        return accepted
    }
    func retire() {
        let previous = lock.withLock { let old = process; process = nil; return old }
        previous?.close()
    }
    func close() {
        let previous = lock.withLock { closed = true; let old = process; process = nil; return old }
        previous?.close()
    }
}

private final class IrohProcess: @unchecked Sendable {
    private struct Startup: Encodable { let seed: Data; let relayURLs: [String]; let directOnly: Bool }
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var cancelled = false
    private let configuration: Startup
    var isRunning: Bool { lock.withLock { !cancelled && process.isRunning } }

    init(executable: URL, arguments: [String], seed: Data, relayURLs: [String], directOnly: Bool) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        configuration = Startup(seed: seed, relayURLs: relayURLs, directOnly: directOnly)
    }
    func close() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }
    func start() throws -> IrohConnection.Ready {
        let deadline = DispatchWorkItem { [weak self] in self?.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { deadline.cancel() }
        do {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try process.run()
                var data = try JSONEncoder().encode(configuration)
                data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
                // Keep stdin open: EOF is the helper's parent-death signal.
            }
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 { break }
                line.append(byte)
                guard line.count <= 8192 else { throw DiscoboxError("Invalid Iroh startup response.") }
            }
            guard !lock.withLock({ cancelled }) else { throw DiscoboxError("Iroh connection setup was cancelled or timed out.", connectionRetryable: true) }
            guard let ready = try? JSONDecoder().decode(IrohConnection.Ready.self, from: line) else {
                throw DiscoboxError("Iroh helper could not start. Rebuild the app and companion together.")
            }
            if let error = ready.error { throw DiscoboxError(error, connectionRetryable: ready.errorKind == "transport") }
            return ready
        } catch { close(); throw error }
    }
    deinit {
        close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
}
