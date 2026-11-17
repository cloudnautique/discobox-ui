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
            startup = (UUID(), Task.detached { try await process.start() })
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
            let ready = try await process.start()
            guard let id = ready.peerID, id.hasPrefix("d1-") else { throw DiscoboxError("The companion returned an invalid peer ID.") }
            return id
        } onCancel: { process.close() }
    }
}

/// close() can interrupt a pending startup without waiting for the actor. An
/// explicitly closed connection never creates another helper.
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

/// One Iroh helper on `CompanionProcess`: the startup configuration is written
/// to stdin once, which then stays open as the parent-death signal, and the
/// first newline-terminated line (at most 8192 bytes, within 20 seconds) is
/// its `Ready` report. Nothing blocks a thread while it starts.
private final class IrohProcess: @unchecked Sendable {
    private struct Startup: Encodable { let seed: Data; let relayURLs: [String]; let directOnly: Bool }
    private let lock = NSLock()
    private let child: CompanionProcess
    private let configuration: Startup
    private var cancelled = false
    private var line = Data()
    // The startup line (or what arrived before EOF/exit), resolved once.
    private var outcome: Result<Data, any Error>?
    private var waiter: CheckedContinuation<Data, any Error>?
    var isRunning: Bool { !lock.withLock { cancelled } && child.hasStarted && !child.hasExited }

    init(executable: URL, arguments: [String], seed: Data, relayURLs: [String], directOnly: Bool) {
        child = CompanionProcess(executable: executable, arguments: arguments, readerName: "Discobox Iroh helper")
        configuration = Startup(seed: seed, relayURLs: relayURLs, directOnly: directOnly)
    }
    func close() {
        let first = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard first else { return }
        child.close()
        // A pending startup ends as cancelled (checked below).
        resolve(.success(lock.withLock { line }))
    }
    func start() async throws -> IrohConnection.Ready {
        let deadline = DispatchWorkItem { [weak self] in self?.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { deadline.cancel() }
        do {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            var data = try JSONEncoder().encode(configuration)
            data.append(10)
            child.write(data, launching: handlers())
            let line = try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Data, any Error>? = lock.withLock {
                    if outcome == nil { waiter = continuation }
                    return outcome
                }
                if let ready { continuation.resume(with: ready) }
            }
            guard !lock.withLock({ cancelled }) else { throw DiscoboxError("Iroh connection setup was cancelled or timed out.", connectionRetryable: true) }
            guard let ready = try? JSONDecoder().decode(IrohConnection.Ready.self, from: line) else {
                throw DiscoboxError("Iroh helper could not start. Rebuild the app and companion together.")
            }
            if let error = ready.error { throw DiscoboxError(error, kind: .init(wire: ready.errorKind)) }
            return ready
        } catch { close(); throw error }
    }

    private func handlers() -> CompanionProcess.Handlers {
        .init(
            output: { [weak self] data in
                guard let self else { return false }
                // Only the first line is read; the helper writes nothing else.
                let (complete, overflow): (Data?, Bool) = lock.withLock {
                    if let end = data.firstIndex(of: 10) {
                        line.append(data[data.startIndex..<end])
                        return line.count <= 8192 ? (line, false) : (nil, true)
                    }
                    line.append(data)
                    return (nil, line.count > 8192)
                }
                if overflow { resolve(.failure(DiscoboxError("Invalid Iroh startup response."))); return false }
                if let complete { resolve(.success(complete)); return false }
                return true
            },
            outputEnded: { [weak self] in self?.resolvePartialLine() },
            // A sibling that inherited stdout can hold EOF back; the exit still
            // ends the startup, after a grace for a line already written.
            exited: { [weak self] _ in self?.resolvePartialLineAfterGrace() },
            failed: { [weak self] failure in
                switch failure {
                case .launch(let error), .write(let error): self?.resolve(.failure(error))
                }
            })
    }
    private func resolvePartialLine() { resolve(.success(lock.withLock { line })) }
    private func resolvePartialLineAfterGrace() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.resolvePartialLine() }
    }
    private func resolve(_ result: Result<Data, any Error>) {
        let continuation: CheckedContinuation<Data, any Error>?? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return .some(waiter)
        }
        if case .some(let waiting?) = continuation { waiting.resume(with: result) }
    }
    deinit { close() }
}
