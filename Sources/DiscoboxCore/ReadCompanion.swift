import Foundation

/// One persistent `--read-server` companion: concurrent read-only requests
/// over one process and HTTP transport, framed as `Companion/internal/readserver`
/// documents. Writes, shells and transfers never come here. Requests carry a
/// transport correlation ID of their own (never `requestID`, which names an
/// approval); replies may arrive in any order. Cancelling or timing out one
/// read sends a cancel frame for that read only. `CompanionProcess` owns the
/// process: launch and writes on its serial queue, reads on its own thread,
/// never the main actor or the cooperative pool. The helper ends, failing every waiter exactly once, when
/// it exits, breaks the framing, or its owner closes it; a closed companion is
/// never reused (`ReadCompanionSlot` starts a fresh one).
final class ReadCompanion: @unchecked Sendable {
    static let protocolVersion = 1
    struct Reply: Sendable, Equatable {
        let status: Int
        let body: Data
        let error: String?
        let errorKind: String?
    }
    /// The companion's frame bound is 128 KiB; larger requests stay one-shot.
    static let maxRequest = 120 << 10
    /// No read's registry deadline is longer (harness review takes 90s); this
    /// only stops a lost reply from holding its caller forever.
    static let backstop: TimeInterval = 120

    let endpoint: String
    private let lock = NSLock()
    private let child: CompanionProcess
    private let frames = FrameReader()
    private var waiters: [UInt64: Waiter] = [:]
    private var ended: (any Error)?

    init(executable: URL, endpoint: String) {
        self.endpoint = endpoint
        child = CompanionProcess(executable: executable, arguments: ["--read-server", "--endpoint", endpoint], readerName: "Discobox read companion")
        Self.registry.withLock { $0[ObjectIdentifier(self)] = Weak(value: self) }
    }
    deinit {
        _ = Self.registry.withLock { $0.removeValue(forKey: ObjectIdentifier(self)) }
        child.close()
    }
    var isUsable: Bool { lock.withLock { ended == nil } }

    /// `timeout` is a client-side deadline (approval reads) and the error it
    /// reports; the companion applies each read's registry deadline itself.
    func perform(_ request: BridgeRequest, timeout: (seconds: TimeInterval, error: DiscoboxError)?) async throws -> Reply {
        try Task.checkCancellation()
        let id = Self.nextID(), frame = try Self.requestFrame(id: id, request), waiter = Waiter()
        try lock.withLock {
            if let ended { throw ended }
            waiters[id] = waiter
        }
        let expiry = timeout ?? (Self.backstop, DiscoboxError("The companion did not answer in time.", connectionRetryable: true))
        let deadline = DispatchWorkItem { [weak self] in self?.abandon(id, waiter, expiry.error) }
        waiter.arm(deadline)
        DispatchQueue.global().asyncAfter(deadline: .now() + expiry.seconds, execute: deadline)
        send(frame)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter.attach($0) }
        } onCancel: { [weak self] in
            if let self { self.abandon(id, waiter, CancellationError()) } else { waiter.resolve(.failure(CancellationError())) }
        }
    }

    /// Ends this helper. Waiters fail with `error`; the process sees EOF (its
    /// parent-death signal) and, since siblings can inherit the pipe on
    /// Linux, a SIGTERM too.
    func close(_ error: any Error = CancellationError()) { end(error) }

    static func closeAll() {
        let all = registry.withLock { $0.values.compactMap(\.value) }
        for companion in all { companion.close() }
    }

    // MARK: Frames

    static func requestFrame(id: UInt64, _ request: BridgeRequest) throws -> Data {
        var frame = Data(#"{"version":\#(protocolVersion),"id":\#(id),"type":"request","request":"#.utf8)
        frame.append(try JSONEncoder().encode(request))
        frame.append(contentsOf: Array("}\n".utf8))
        return frame
    }
    static func cancelFrame(id: UInt64) -> Data { Data(#"{"version":\#(protocolVersion),"id":\#(id),"type":"cancel"}"#.utf8 + [10]) }

    /// Splits companion output into replies: a JSON header line, then
    /// `bodyLength` raw bytes. Anything else ends the helper.
    struct Frames {
        private struct Header: Decodable {
            let version: Int
            let id: UInt64
            let status: Int
            let bodyLength: Int
            let error: String?
            let errorKind: String?
        }
        static let maxHeader = 64 << 10
        static let maxBody = 12 << 20
        private var buffer = Data()
        private var header: Header?

        mutating func append(_ data: Data) throws -> [(id: UInt64, reply: Reply)] {
            buffer.append(data)
            var replies: [(UInt64, Reply)] = []
            while true {
                if header == nil {
                    guard let end = buffer.firstIndex(of: 10) else {
                        guard buffer.count <= Self.maxHeader else { throw Self.invalid }
                        return replies
                    }
                    let line = buffer[buffer.startIndex..<end]
                    buffer = Data(buffer[buffer.index(after: end)...])
                    guard let next = try? JSONDecoder().decode(Header.self, from: line) else { throw Self.invalid }
                    guard next.version == ReadCompanion.protocolVersion else {
                        throw DiscoboxError("Unsupported companion protocol version. Rebuild the app and companion together.")
                    }
                    guard (0...Self.maxBody).contains(next.bodyLength) else { throw DiscoboxError("Companion response exceeded the size limit.") }
                    header = next
                }
                guard let current = header, buffer.count >= current.bodyLength else { return replies }
                let body = Data(buffer.prefix(current.bodyLength))
                buffer = Data(buffer.dropFirst(current.bodyLength))
                header = nil
                replies.append((current.id, Reply(status: current.status, body: body, error: current.error, errorKind: current.errorKind)))
            }
        }
        static let invalid = DiscoboxError("The companion returned an invalid response. Rebuild the app and companion together.")
    }

    // MARK: Lifetime

    /// The first frame launches the helper (on the child's writer queue), so
    /// an idle connection never starts one.
    private func send(_ frame: Data) {
        guard isUsable else { return }
        child.write(frame, launching: handlers())
    }

    /// Callbacks hold this companion weakly: releasing it still closes the
    /// child's stdin and ends the helper.
    private func handlers() -> CompanionProcess.Handlers {
        let frames = frames
        return .init(
            output: { [weak self] data in
                guard let self else { return false }
                do {
                    for (id, reply) in try frames.append(data) { deliver(id, reply) }
                    return true
                } catch {
                    end(error); return false
                }
            },
            // EOF normally means exit; the exit callback reports its status
            // like a one-shot request, and this ends a helper that only
            // closed its output.
            outputEnded: { [weak self] in self?.endAfterGrace() },
            exited: { [weak self] status in
                self?.end(DiscoboxError("The companion exited unexpectedly (\(status)).", connectionRetryable: true))
            },
            failed: { [weak self] failure in
                switch failure {
                case .launch(let error): self?.end(DiscoboxError("Could not launch the companion. Build the app with scripts/build-app.sh. \(error.localizedDescription)"))
                case .write: self?.end(DiscoboxError("The companion exited unexpectedly.", connectionRetryable: true))
                }
            })
    }

    private func endAfterGrace() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.end(DiscoboxError("The companion exited unexpectedly.", connectionRetryable: true))
        }
    }

    /// Reply framing state, used only on the reader thread.
    private final class FrameReader: @unchecked Sendable {
        private var frames = Frames()
        func append(_ data: Data) throws -> [(id: UInt64, reply: Reply)] { try frames.append(data) }
    }

    private func deliver(_ id: UInt64, _ reply: Reply) {
        guard id != 0 else {
            // A stream-level failure: nothing can be attributed any more.
            end(DiscoboxError(reply.error ?? Frames.invalid.message, kind: .init(wire: reply.errorKind)))
            return
        }
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resolve(.success(reply))
    }

    /// Fails one read without touching the others; the helper stops its work.
    private func abandon(_ id: UInt64, _ waiter: Waiter, _ error: any Error) {
        let pending = lock.withLock { ended == nil && waiters.removeValue(forKey: id) != nil }
        if waiter.resolve(.failure(error)), pending { send(Self.cancelFrame(id: id)) }
    }

    private func end(_ error: any Error) {
        let failed: [Waiter] = lock.withLock {
            guard ended == nil else { return [] }
            ended = error
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        child.close()
        for waiter in failed { waiter.resolve(.failure(error)) }
    }

    // MARK: Shared state

    private struct Weak { weak var value: ReadCompanion? }
    private static let registry = Locked<[ObjectIdentifier: Weak]>([:])
    // IDs are unique across helpers, so a reply can never match a request
    // that was sent to a different helper or generation.
    private static let ids = Locked<UInt64>(0)
    private static func nextID() -> UInt64 { ids.withLock { $0 += 1; return $0 } }

    /// One read's continuation, resumed exactly once by whichever comes first:
    /// its reply, cancellation, its deadline, or the helper ending.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Reply, any Error>?
        private var outcome: Result<Reply, any Error>?
        private var deadline: DispatchWorkItem?
        func arm(_ item: DispatchWorkItem) {
            let resolved = lock.withLock { if outcome == nil { deadline = item }; return outcome != nil }
            if resolved { item.cancel() }
        }
        func attach(_ continuation: CheckedContinuation<Reply, any Error>) {
            let ready: Result<Reply, any Error>? = lock.withLock {
                if outcome == nil { self.continuation = continuation }
                return outcome
            }
            if let ready { continuation.resume(with: ready) }
        }
        @discardableResult func resolve(_ result: Result<Reply, any Error>) -> Bool {
            let resumed: (CheckedContinuation<Reply, any Error>?, DispatchWorkItem?)? = lock.withLock {
                guard outcome == nil else { return nil }
                outcome = result
                defer { continuation = nil }
                return (continuation, deadline)
            }
            guard let resumed else { return false }
            resumed.1?.cancel()
            resumed.0?.resume(with: result)
            return true
        }
    }
}

/// The current read companion of one `CompanionClient`, i.e. of one
/// connection generation. A dead helper is replaced on the next read; a new
/// generation or a different transport endpoint (a restarted Iroh proxy)
/// retires it; a closed slot starts nothing, so reads after
/// `closeConnection()` use one-shot helpers instead of leaking a process.
final class ReadCompanionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private var current: ReadCompanion?
    private var closed = false
    init(executable: URL) { self.executable = executable }

    func companion(for endpoint: String) -> ReadCompanion? {
        let (chosen, retired): (ReadCompanion?, ReadCompanion?) = lock.withLock {
            if closed { return (nil, nil) }
            if let current, current.isUsable, current.endpoint == endpoint { return (current, nil) }
            let previous = current
            current = ReadCompanion(executable: executable, endpoint: endpoint)
            return (current, previous)
        }
        retired?.close(DiscoboxError("The connection changed while the request was in flight. Try again.", connectionRetryable: true))
        return chosen
    }
    /// Ends the current helper; its pending reads fail as cancelled.
    func retire(reopen: Bool) {
        let previous: ReadCompanion? = lock.withLock {
            closed = !reopen
            defer { current = nil }
            return current
        }
        previous?.close()
    }
    deinit { current?.close() }
}

/// A value behind a lock, for the few process-wide registries.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&value) }
    }
}
