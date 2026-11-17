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
/// - stdout is read on a dedicated thread (`CompanionProcess`), never the
///   main actor or the cooperative pool. Lines are bounded by `maxLineBytes`
///   and decoded there; `events` delivers them in order.
/// - `close()` is idempotent and also runs on deinit: it closes stdin, sends
///   SIGTERM, then SIGKILL if the child outlives `killAfter`. After close no
///   further events are delivered and `events` finishes.
///
/// Reads share `ReadCompanion`; other request/response calls keep their own
/// per-request processes (`CompanionClient`); terminal PTY children are owned
/// by Ghostty.
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
    private let child: CompanionProcess
    private let maxLineBytes: Int

    public init(executable: URL, arguments: [String], maxLineBytes: Int = 1024 * 1024, killAfter: Duration = .seconds(2)) {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        state = CompanionChildState(continuation: continuation)
        self.maxLineBytes = maxLineBytes
        child = CompanionProcess(executable: executable, arguments: arguments, killAfter: killAfter,
                                 readerName: "Discobox companion output", readerQoS: .userInitiated)
    }

    public var isRunning: Bool { state.withLock { !$0.closed && $0.started } && !child.hasExited }
    /// For tests: the launched child's pid, or 0.
    var processIdentifier: Int32 { child.processIdentifier }

    /// Launches the child. Throws if it cannot start or was already started or
    /// closed; a child that failed to launch is closed.
    public func start() throws {
        let state = state, lines = LineReader(limit: maxLineBytes, state: state)
        state.withLock { _ in state.onOverflow = { [weak self] in self?.close() } }
        do {
            try child.start(.init(
                output: { lines.append($0) },
                outputEnded: { state.finish(.exited) },
                // A child whose stdout a sibling inherited never delivers
                // EOF; its exit still ends the stream, after a short grace
                // for output it already wrote.
                exited: { _ in DispatchQueue.global().asyncAfter(deadline: .now() + 1) { state.finish(.exited) } }))
        } catch {
            close()
            throw error
        }
        state.withLock { $0.started = true }
    }

    /// Idempotent. Closes stdin (the child's parent-death signal), sends
    /// SIGTERM, and SIGKILL if the child is still running after `killAfter`.
    public func close() {
        state.close()
        child.close()
    }

    deinit { close() }

    /// Splits output into bounded lines and decodes them, on the reader thread.
    private final class LineReader: @unchecked Sendable {
        private var pending = Data()
        private let decoder = JSONDecoder()
        private let limit: Int
        private let state: CompanionChildState<Message>
        init(limit: Int, state: CompanionChildState<Message>) { self.limit = limit; self.state = state }
        func append(_ data: Data) -> Bool {
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[pending.startIndex..<end])
                pending.removeSubrange(pending.startIndex...end)
                guard line.count <= limit else { state.overflowed(); return false }
                do { state.deliver(.message(try decoder.decode(Message.self, from: line))) }
                catch { state.deliver(.invalidLine(error.localizedDescription)) }
            }
            guard pending.count <= limit else { state.overflowed(); return false }
            return !state.isFinished
        }
    }
}

private final class CompanionChildState<Message: Decodable & Sendable>: @unchecked Sendable {
    struct Flags {
        var started = false, closed = false, finished = false
    }
    private let lock = NSLock()
    private var flags = Flags()
    private let continuation: AsyncStream<CompanionChild<Message>.Event>.Continuation
    /// Closes the owning child after its output overflowed; set under the lock.
    var onOverflow: (@Sendable () -> Void)?
    init(continuation: AsyncStream<CompanionChild<Message>.Event>.Continuation) { self.continuation = continuation }

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
    func close() {
        withLock { flags in
            guard !flags.closed else { return }
            flags.closed = true
            if !flags.finished { flags.finished = true; continuation.finish() }
        }
    }
}
