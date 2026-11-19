import Foundation

struct ProjectBoxEvent: Decodable, Sendable {
    let projectId, sandboxId, name, state, displayState: String
    let runtimeState, errorMessage: String?
    let tags: [String: String]?
    let program: Program?
    var parentSandboxId: String?
    struct Program: Codable, Equatable, Sendable {
        let state: String
        let kind: String?
    }
}

struct ProjectEventFrame: Decodable, Sendable {
    enum Kind: String, Decodable { case event, checkpoint, reset, heartbeat, retry, unsupported, error }
    let version: Int
    let kind: Kind
    let id: Int64?
    let type: String?
    let data: ProjectBoxEvent?
    let retry: Int64?
    var wireBytes = 0
    private enum CodingKeys: String, CodingKey { case version, kind, id, type, data, retry }
}

typealias ProjectEventReceiver = @MainActor @Sendable ([ProjectEventFrame]) throws -> Void
protocol ProjectEventSource: Sendable {
    func readEvents(endpoint: String, project: String, generation: UUID, after: Int64?, receive: @escaping ProjectEventReceiver) async throws
}

// Exactly one decoded chunk may await delivery. Backpressure reaches the pipe
// instead of building an unbounded queue of main-actor tasks.
final class EventProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var cancelled = false

    init(executable: URL, endpoint: String, project: String, generation: UUID, after: Int64?) {
        process.executableURL = executable
        process.arguments = ["--events", "--endpoint", endpoint, "--project", project, "--diagnostic-connection", generation.uuidString] +
            (after.map { ["--after-event-id", String($0)] } ?? [])
        var environment = ProcessInfo.processInfo.environment
        environment["DISCOBOX_UI_AUTOMATIC_GUEST_READS"] = GuestReadDiagnostics.automaticReadsDisabled ? "paused" : "enabled"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    func run(receive: @escaping ProjectEventReceiver) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
        defer {
            try? input.fileHandleForWriting.close()
            cancel()
            process.waitUntilExit()
        }
        let decoder = JSONDecoder()
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw DiscoboxError("Project event stream ended.") }
            pending.append(chunk)
            var batch: [ProjectEventFrame] = []
            while let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]
                guard line.count <= 1 << 20 else { throw DiscoboxError("Project event line too large.") }
                var frame = try decoder.decode(ProjectEventFrame.self, from: line)
                guard frame.version == 1 else { throw DiscoboxError("Unsupported project event version.") }
                frame.wireBytes = line.count
                batch.append(frame)
                pending.removeSubrange(...end)
            }
            guard pending.count <= 1 << 20 else { throw DiscoboxError("Project event line too large.") }
            if !batch.isEmpty {
                let delivery = Delivery()
                let frames = batch
                Task { @MainActor in
                    delivery.result = Result { try receive(frames) }
                    delivery.ready.signal()
                }
                delivery.ready.wait()
                try delivery.result.get()
            }
        }
    }
    private final class Delivery: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .success(())
    }
}

extension CompanionClient: ProjectEventSource {
    func readEvents(endpoint: String, project: String, generation: UUID, after: Int64?, receive: @escaping ProjectEventReceiver) async throws {
        let job = EventProcess(executable: executable, endpoint: endpoint, project: project, generation: generation, after: after)
        try await withTaskCancellationHandler {
            try await BlockingThread.run(name: "Discobox project events", priority: .utility) { try job.run(receive: receive) }
        } onCancel: { job.cancel() }
    }
}

// The server sends the configured handle in name. Display names, terminal
// titles, pool reports and repository metadata come from the DB-backed list.
extension ProjectBoxEvent {
    func applying(to metadata: Sandbox?) -> Sandbox {
        let runtime = metadata?.runtime
        let config = metadata?.config
        var box = Sandbox(id: sandboxId, projectId: projectId, parentSandboxId: parentSandboxId,
                          displayName: metadata?.displayName ?? name,
                          config: .init(name: name, model: config?.model, harnessConfigId: config?.harnessConfigId, source: config?.source),
                          runtime: .init(state: state, runtimeState: runtimeState, errorMessage: errorMessage,
                                         errorReason: errorMessage == nil ? nil : runtime?.errorReason,
                                         lastActiveAt: runtime?.lastActiveAt, displayState: displayState,
                                         stateReportedAt: runtime?.stateReportedAt, agentStatus: runtime?.agentStatus,
                                         resources: runtime?.resources, upgrade: runtime?.upgrade),
                          meta: .init(name: metadata?.meta?.name, description: metadata?.meta?.description, tags: tags),
                          poolId: metadata?.poolId, platform: metadata?.platform, createdAt: metadata?.createdAt,
                          harnessConfig: metadata?.harnessConfig, discoboxApi: metadata?.discoboxApi,
                          preparationStatus: metadata?.preparationStatus)
        box.projectProgram = .init(state: program?.state ?? "", kind: program?.kind)
        return box
    }
}

struct ProjectEventReplay {
    enum Change {
        case none, stale, replace([String: ProjectBoxEvent]), update(ProjectBoxEvent), delete(String)
    }
    private(set) var cursor: Int64?
    private var staging: [String: ProjectBoxEvent]? = [:]
    private var lastStaged: Int64?
    private var stagingBytes = 0

    mutating func interrupted() {
        // A partial replay never became inventory. Retry from its beginning.
        if staging != nil { self = Self() }
    }

    mutating func accept(_ frame: ProjectEventFrame, project: String) throws -> Change {
        switch frame.kind {
        case .reset:
            self = Self()
            return .stale
        case .checkpoint:
            guard let id = frame.id, id >= 0 else { throw DiscoboxError("Missing event checkpoint.") }
            if let staged = staging {
                guard id >= (lastStaged ?? 0) else { throw DiscoboxError("Incomplete event replay.") }
                staging = nil
                cursor = id
                return .replace(staged)
            }
            cursor = max(cursor ?? 0, id)
            return .none
        case .event:
            guard let id = frame.id, id >= 0, let box = frame.data, box.projectId == project, !box.sandboxId.isEmpty,
                  let type = frame.type, ["sandbox.created", "sandbox.updated", "sandbox.deleted"].contains(type)
            else { throw DiscoboxError("Invalid project event.") }
            if let previous = lastStaged, staging != nil, id <= previous { return .none }
            if let cursor, id <= cursor { return .none }
            let deleted = type == "sandbox.deleted" || box.state == "deleted"
            if staging != nil {
                stagingBytes += frame.wireBytes
                guard stagingBytes <= 16 << 20 else { throw DiscoboxError("Project event replay too large.") }
                staging?[box.sandboxId] = deleted ? nil : box
                lastStaged = id
                return .none
            }
            cursor = id
            return deleted ? .delete(box.sandboxId) : .update(box)
        default: return .none
        }
    }
}

@MainActor final class ProjectEventSubscription {
    typealias Publish = @MainActor (_ changes: [ProjectEventReplay.Change]?, _ current: Bool) throws -> Void
    private var endpoint: String?
    private var reader: Task<Void, Never>?
    private var generation = UUID()

    func start(source: any ProjectEventSource, project: String, endpoint: String, connection: UUID, publish: @escaping Publish) {
        guard self.endpoint != endpoint else { return }
        stop()
        self.endpoint = endpoint
        let owner = generation
        reader = Task(priority: .utility) { [weak self] in
            var replay = ProjectEventReplay(), hint = 2.0, failures = 0
            var unsupported = false
            while !Task.isCancelled {
                do {
                    try await source.readEvents(endpoint: endpoint, project: project, generation: connection, after: replay.cursor) { [weak self] frames in
                        guard self?.generation == owner else { throw CancellationError() }
                        var next = replay
                        var changes: [ProjectEventReplay.Change] = []
                        for frame in frames {
                            if frame.kind == .unsupported { unsupported = true; return }
                            if let ms = frame.retry { hint = min(60, max(1, Double(ms) / 1000)) }
                            let change = try next.accept(frame, project: project)
                            if case .none = change { continue }
                            changes.append(change)
                        }
                        try publish(changes, next.cursor != nil)
                        replay = next
                        if frames.contains(where: { $0.kind == .heartbeat }) { failures = 0 }
                    }
                } catch { /* The last accepted cursor survives a broken attachment. */ }
                guard self?.generation == owner, !Task.isCancelled else { return }
                do { try publish(nil, false) } catch { return }
                if unsupported { return }
                replay.interrupted()
                let delay = min(60, hint * pow(2, Double(failures)))
                failures = min(6, failures + 1)
                do { try await Task.sleep(for: .seconds(min(60, delay + Double.random(in: 0...delay / 5)))) } catch { return }
            }
        }
    }
    func stop() {
        generation = UUID()
        reader?.cancel(); reader = nil
        endpoint = nil
    }
    deinit { reader?.cancel() }
}
