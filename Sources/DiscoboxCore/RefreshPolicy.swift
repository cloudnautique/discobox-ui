import Foundation
import Observation

public struct RefreshPolicy: Codable, Equatable, Sendable {
    public var manual = false
    public var pauseDetails = false
    public var pauseUsage = false
    public init() {}
    func allows(_ loop: PollingLoop) -> Bool {
        guard !manual else { return false }
        switch loop {
        case .details: return !pauseDetails && !GuestReadDiagnostics.automaticReadsDisabled
        case .usage: return !pauseUsage && !GuestReadDiagnostics.automaticReadsDisabled
        default: return true
        }
    }
}

struct ScheduledReadContext: Sendable {
    let generation: UUID
    let loop: PollingLoop
    let metrics: ReadMetrics
    var budget: GuestReadBudget? = nil
}

/// Track actual companion read dispatches. A queued/detached read checks
/// again at registration, just before its helper is allowed to launch.
@MainActor @Observable public final class ReadMetrics {
    public private(set) var started = 0
    public private(set) var finished = 0
    public private(set) var cancelled = 0
    public var inFlight: Int { started - finished - cancelled }
    @ObservationIgnored private var jobs: [UUID: (PollingLoop, @Sendable () -> Void)] = [:]
    @ObservationIgnored var policy = RefreshPolicy()
    func begin(_ kind: PollingLoop, cancel: @escaping @Sendable () -> Void) throws -> UUID {
        guard policy.allows(kind), !Task.isCancelled else { throw CancellationError() }
        let id = UUID()
        jobs[id] = (kind, cancel)
        started += 1
        return id
    }
    func end(_ id: UUID, cancelled wasCancelled: Bool) {
        guard jobs.removeValue(forKey: id) != nil else { return }
        if wasCancelled { cancelled += 1 } else { finished += 1 }
    }
    func apply(_ value: RefreshPolicy) {
        policy = value
        for (kind, cancel) in jobs.values where !value.allows(kind) { cancel() }
    }
}
