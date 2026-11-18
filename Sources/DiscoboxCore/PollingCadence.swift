import Foundation

/// What a person can currently see of the workspace window. Desktop derives it
/// from app activation and window occlusion; Core never reads AppKit.
public enum PollingPresence: Sendable, Equatable {
    /// Frontmost app with the workspace window on screen.
    case focused
    /// Window on screen while another app is frontmost.
    case visible
    /// Window occluded, miniaturized, closed or the app hidden.
    case hidden
}

public enum GuestReadDiagnostics {
    @TaskLocal static var scheduled = false
    @TaskLocal static var context: ScheduledReadContext?

    /// Capture once so all sessions and their helpers use the same experiment.
    public static let recoveryDisabled = automaticReadsDisabled || UserDefaults.standard.bool(forKey: "DiscoboxDisableTerminalRecovery")
    public static let automaticReadsDisabled = UserDefaults.standard.bool(forKey: "DiscoboxDisableAutomaticGuestReads")
}

public enum PollingLoop: Sendable, CaseIterable { case inventory, approvals, resources, usage, details }

/// Every poll launches a companion process, so cadence follows what can be
/// seen. Approvals never pause: macOS notifications are the only way a hidden
/// app reports an agent waiting on a person, so they slow to a bounded delay.
/// Resources and usage only feed visible panels, which refresh on open.
public struct PollingCadence: Sendable, Equatable {
    public var presence: PollingPresence
    public var isActiveHost: Bool
    public var usageVisible: Bool
    public init(presence: PollingPresence = .focused, isActiveHost: Bool = true, usageVisible: Bool = true) {
        self.presence = presence; self.isActiveHost = isActiveHost; self.usageVisible = usageVisible
    }
    /// Nil pauses the loop until the cadence changes.
    public func interval(_ loop: PollingLoop) -> Duration? {
        switch (presence, loop) {
        case (.focused, .inventory): .seconds(isActiveHost ? 3 : 10)
        case (.focused, .approvals): .seconds(isActiveHost ? 2 : 5)
        case (.visible, .inventory): .seconds(15)
        case (.visible, .approvals): .seconds(5)
        case (.hidden, .inventory): .seconds(60)
        case (.hidden, .approvals): .seconds(10)
        case (.hidden, .resources), (.hidden, .usage): nil
        case (_, .details): isActiveHost && presence != .hidden ? .seconds(presence == .focused ? 30 : 60) : nil
        case (_, .resources): .seconds(30)
        case (_, .usage): usageVisible ? .seconds(60) : nil
        }
    }
    /// Time left before the next poll, or nil to wait for a cadence change; a
    /// loop that has never polled is due at once. Recovery keeps its own 2-30
    /// second backoff whatever the presence: a scheduled retry is never later
    /// than its deadline (with a 50 ms floor so an unready retry cannot spin).
    public func delay(_ loop: PollingLoop, sinceLastPoll elapsed: Duration?, retryIn: TimeInterval? = nil) -> Duration? {
        let regular = interval(loop).map { interval in elapsed.map { interval - $0 } ?? .zero }
        guard let retryIn else { return regular }
        let retry = retryIn > 0.05 ? Duration.seconds(retryIn) : .milliseconds(50)
        return regular.map { min($0, retry) } ?? retry
    }
}

/// Loops sleep here so a cadence or recovery change takes effect at once rather
/// than after a long background interval, without interrupting a poll in flight.
/// Timed sleeps go through the session's injectable `pollSleep`.
@MainActor final class PollingSchedule {
    private var waiters: [UUID: (continuation: CheckedContinuation<Bool, Never>, timer: Task<Void, Never>?)] = [:]

    /// True when woken early so the caller recomputes its deadline; false once
    /// the delay elapses. Nil sleeps until woken. Throws only on cancellation.
    func sleep(_ loop: PollingLoop, seconds: Double?, using sleep: @escaping @Sendable (PollingLoop, Double) async throws -> Void) async throws -> Bool {
        let id = UUID()
        let woken = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let timer = seconds.map { seconds in Task { [weak self] in
                    do { try await sleep(loop, seconds) } catch { return }
                    self?.resume(id, woken: false)
                } }
                waiters[id] = (continuation, timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id, woken: false) }
        }
        try Task.checkCancellation()
        return woken
    }
    func wake() { for id in Array(waiters.keys) { resume(id, woken: true) } }
    private func resume(_ id: UUID, woken: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer?.cancel(); waiter.continuation.resume(returning: woken)
    }
}
