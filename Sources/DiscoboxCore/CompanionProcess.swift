import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The process plumbing shared by long-lived companion children
/// (`CompanionChild`'s line-JSON events, `ReadCompanion`'s framed reads,
/// the Iroh helper's startup handshake);
/// neither constructs a Process, Pipe or thread itself.
///
/// - stdin stays open for the child's whole life: EOF is its parent-death
///   signal, including when the app exits unexpectedly. Writes, if any, run on
///   one serial queue with SIGPIPE suppressed.
/// - stdout is read with read(2) on a dedicated thread, never the main actor
///   or the cooperative pool. `FileHandle.read(upToCount:)` would wait for the
///   whole count on Linux and hold a short reply indefinitely.
/// - Exit is reported by the termination handler, independently of stdout
///   EOF, which a sibling that inherited the pipe (Linux Foundation) can hold
///   back forever.
/// - `close()` is idempotent and also runs on deinit: no callback is made
///   after it; it closes stdin, sends SIGTERM, then SIGKILL if the child
///   outlives `killAfter`. Neither the reader thread nor the termination
///   handler retains this object, so dropping the owner reaches deinit.
final class CompanionProcess: @unchecked Sendable {
    enum Failure: Error {
        /// A lazy launch (`write(_:launching:)`) failed.
        case launch(any Error)
        /// Writing to the child's stdin failed (it has gone away).
        case write(any Error)
    }
    struct Handlers: Sendable {
        /// Output bytes in order, on the reader thread. Return false to stop reading.
        var output: @Sendable (Data) -> Bool
        /// stdout reached EOF (or failed) on the reader thread.
        var outputEnded: @Sendable () -> Void = {}
        /// The child exited with this status.
        var exited: @Sendable (Int32) -> Void = { _ in }
        var failed: @Sendable (Failure) -> Void = { _ in }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer: DispatchQueue
    private let shared = Shared()
    private let killAfter: Duration
    private let readerName: String
    private let readerQoS: QualityOfService

    init(executable: URL, arguments: [String], killAfter: Duration = .seconds(2),
         readerName: String = "Discobox companion output", readerQoS: QualityOfService = .default) {
        self.killAfter = killAfter; self.readerName = readerName; self.readerQoS = readerQoS
        writer = DispatchQueue(label: "\(readerName) writer")
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }
    deinit { close() }

    var processIdentifier: Int32 { shared.withLock { $0.pid } }
    var hasStarted: Bool { shared.withLock { $0.started } }
    var hasExited: Bool { shared.withLock { $0.exited } }
    var isClosed: Bool { shared.withLock { $0.closed } }

    /// Launches the child. Throws `CancellationError` if it was already
    /// started or closed; a child that failed to launch is closed.
    func start(_ handlers: Handlers) throws {
        let shared = shared
        do {
            try shared.withLock { state in
                guard !state.closed, !state.started else { throw CancellationError() }
                state.started = true
                state.handlers = handlers
                process.terminationHandler = { process in
                    let status = process.terminationStatus
                    shared.withLock { $0.exited = true }
                    shared.callback { $0.exited }?(status)
                }
                try process.run()
                state.pid = process.processIdentifier
            }
        } catch {
            close()
            throw error
        }
        // The parent's copy of the write end would hold EOF back forever.
        try? output.fileHandleForWriting.close()
        let handle = output.fileHandleForReading
        let thread = Thread { Self.readLoop(handle, shared) }
        thread.name = readerName
        thread.qualityOfService = readerQoS
        thread.start()
    }

    /// Writes on the serial writer queue, launching first (with `handlers`)
    /// if the child has not started, so a caller on the cooperative pool never
    /// blocks on the spawn or the pipe. Failures go to `handlers.failed`.
    func write(_ data: Data, launching handlers: Handlers) {
        writer.async { [self] in
            if !hasStarted {
                do { try start(handlers) } catch is CancellationError { return } catch { handlers.failed(.launch(error)); return }
            }
            guard !isClosed else { return }
            Self.suppressBrokenPipeSignal(input.fileHandleForWriting)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { shared.callback { $0.failed }?(.write(error)) }
        }
    }

    /// Idempotent; see the type comment.
    func close() {
        let pid: Int32? = shared.withLock { state in
            guard !state.closed else { return nil }
            state.closed = true
            state.handlers = nil
            return state.pid
        }
        guard let pid else { return }
        // On the writer queue, so a write in progress never races the close.
        writer.async { [input] in try? input.fileHandleForWriting.close() }
        let shared = shared
        guard pid > 0, !shared.withLock({ $0.exited }) else { return }
        kill(pid, SIGTERM)
        let grace = killAfter.components
        let delay = Double(grace.seconds) + Double(grace.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if !shared.withLock({ $0.exited }) { kill(pid, SIGKILL) }
        }
    }

    private static func readLoop(_ handle: FileHandle, _ shared: Shared) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            guard let output = shared.callback({ $0.output }), output(Data(buffer[..<count])) else { return }
        }
        shared.callback { $0.outputEnded }?()
    }

    /// A child that dies mid-write must not kill the app with SIGPIPE.
    private static func suppressBrokenPipeSignal(_ handle: FileHandle) {
        #if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
    }

    /// State the reader thread and termination handler share without
    /// retaining the CompanionProcess.
    private final class Shared: @unchecked Sendable {
        struct State {
            var started = false, closed = false, exited = false
            var pid: Int32 = 0
            var handlers: Handlers?
        }
        private let lock = NSLock()
        private var state = State()
        func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body(&state)
        }
        /// A handler, unless closed; called outside the lock.
        func callback<T>(_ pick: (Handlers) -> T) -> T? {
            withLock { $0.closed ? nil : $0.handlers.map(pick) }
        }
    }
}
