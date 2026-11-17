import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One long-lived companion child that reports newline-delimited JSON, such as
/// `--forward` port snapshots or the `--desktop` proxy address.
///
/// - Its stdin stays open and is never written: EOF is the child's
///   parent-death signal, including when the app itself exits unexpectedly.
/// - stdout is read on a dedicated thread (see `BlockingThread`), never the
///   main actor or the cooperative pool. Lines are bounded by `maxLineBytes`
///   and decoded there; `events` delivers them in order.
/// - `close()` is idempotent and also runs on deinit: it closes stdin, sends
///   SIGTERM, then SIGKILL if the child outlives `killAfter`. After close no
///   further events are delivered and `events` finishes.
///
/// Request/response companion calls keep their own per-request processes
/// (`CompanionClient`); terminal PTY children are owned by Ghostty.
public final class CompanionChild<Message: Decodable & Sendable>: @unchecked Sendable {
    public enum Event: Sendable {
        case message(Message)
        /// A complete line that did not decode as `Message`.
        case invalidLine(String)
        /// The child stopped on its own (or a line exceeded the bound, after
        /// which the child is closed). Always the last event.
        case ended(Ending)
    }
    public enum Ending: Sendable, Equatable {
        case exited
        case lineTooLong
    }

    public let events: AsyncStream<Event>
    private let state: CompanionChildState<Message>
    private let process = Process()
    private let input = Pipe()
    private let output: Pipe
    private let maxLineBytes: Int
    private let killAfter: Duration

    public init(executable: URL, arguments: [String], maxLineBytes: Int = 1024 * 1024, killAfter: Duration = .seconds(2)) {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let output = Pipe()
        self.events = events
        self.output = output
        state = CompanionChildState(continuation: continuation, output: output.fileHandleForReading)
        self.maxLineBytes = maxLineBytes
        self.killAfter = killAfter
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public var isRunning: Bool { state.withLock { !$0.closed && !$0.exited && $0.started } }
    /// For tests: the launched child's pid, or 0.
    var processIdentifier: Int32 { state.withLock { $0.pid } }

    /// Launches the child. Throws if it cannot start or was already started or
    /// closed; a child that failed to launch is closed.
    public func start() throws {
        let state = state, limit = maxLineBytes
        do {
            try state.withLock { flags in
                guard !flags.closed, !flags.started else { throw CancellationError() }
                flags.started = true
                state.onOverflow = { [weak self] in self?.close() }
                // A child whose stdout a sibling inherited (possible on Linux
                // Foundation) never delivers EOF; its exit still ends the
                // stream, after a short grace for output it already wrote.
                process.terminationHandler = { _ in
                    state.withLock { $0.exited = true }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { state.finish(.exited) }
                }
                try process.run()
                flags.pid = process.processIdentifier
            }
        } catch {
            close()
            throw error
        }
        // The parent's copy of the write end would hold EOF back forever.
        try? output.fileHandleForWriting.close()
        let thread = Thread { CompanionChild.readLines(limit: limit, state: state) }
        thread.name = "Discobox companion output"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs on its own thread and never retains the CompanionChild, so
    /// dropping the owner still reaches deinit, which closes the child.
    private static func readLines(limit: Int, state: CompanionChildState<Message>) {
        var pending = Data()
        let decoder = JSONDecoder()
        // FileHandle.read(upToCount:) waits for the full count or EOF; a POSIX
        // read returns whatever a line-at-a-time child has written so far.
        let descriptor = state.output.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[..<count])
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[pending.startIndex..<end])
                pending.removeSubrange(pending.startIndex...end)
                guard line.count <= limit else { state.overflowed(); return }
                do { state.deliver(.message(try decoder.decode(Message.self, from: line))) }
                catch { state.deliver(.invalidLine(error.localizedDescription)) }
            }
            guard pending.count <= limit else { state.overflowed(); return }
            if state.isFinished { return }
        }
        state.finish(.exited)
    }

    /// Idempotent. Closes stdin (the child's parent-death signal), sends
    /// SIGTERM, and SIGKILL if the child is still running after `killAfter`.
    public func close() {
        guard let pid = state.close() else { return }
        try? input.fileHandleForWriting.close()
        let state = state
        guard !state.withLock({ $0.exited }) else { return }
        kill(pid, SIGTERM)
        let grace = killAfter.components
        let delay = Double(grace.seconds) + Double(grace.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if !state.withLock({ $0.exited }) { kill(pid, SIGKILL) }
        }
    }

    deinit { close() }
}

private final class CompanionChildState<Message: Decodable & Sendable>: @unchecked Sendable {
    struct Flags {
        var started = false, closed = false, finished = false, exited = false
        var pid: Int32 = 0
    }
    private let lock = NSLock()
    private var flags = Flags()
    private let continuation: AsyncStream<CompanionChild<Message>.Event>.Continuation
    let output: FileHandle
    /// Closes the owning child after its output overflowed; set under the lock.
    var onOverflow: (@Sendable () -> Void)?
    init(continuation: AsyncStream<CompanionChild<Message>.Event>.Continuation, output: FileHandle) {
        self.continuation = continuation; self.output = output
    }

    func withLock<T>(_ body: (inout Flags) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&flags)
    }
    var isFinished: Bool { withLock { $0.finished } }
    func deliver(_ event: CompanionChild<Message>.Event) {
        withLock { flags in if !flags.finished { continuation.yield(event) } }
    }
    func finish(_ ending: CompanionChild<Message>.Ending) {
        withLock { flags in
            guard !flags.finished else { return }
            flags.finished = true
            continuation.yield(.ended(ending))
            continuation.finish()
        }
    }
    func overflowed() {
        finish(.lineTooLong)
        withLock { $0.closed ? nil : onOverflow }?()
    }
    /// Marks the child closed, ending `events` without a further event.
    /// Returns its pid the first time if it was launched.
    func close() -> Int32? {
        withLock { flags in
            guard !flags.closed else { return nil }
            flags.closed = true
            if !flags.finished { flags.finished = true; continuation.finish() }
            return flags.pid > 0 ? flags.pid : nil
        }
    }
}
