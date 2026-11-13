import Foundation

/// Box power is the steady signal; attention and failures take precedence.
/// Agent activity adds motion only when it is explicitly reported as working.
public struct BoxIndicator: Sendable, Equatable {
    public enum State: Sendable { case on, off, attention, error, unavailable }
    public let state: State
    public let isWorking: Bool

    public init(box: Sandbox, activity: AgentActivity, reachable: Bool = true) {
        if !reachable { state = .unavailable }
        else if box.isArchived || box.isDeleted { state = .off }
        else if box.needsRepair || activity.state == .failed { state = .error }
        else if activity.needsYou || box.runningWarning != nil || box.isRepairing { state = .attention }
        else if box.isRunning { state = .on }
        else if box.runtime.runtimeState == "stopped" || box.runtime.displayState == "stopped" { state = .off }
        else { state = .unavailable }
        isWorking = state == .on && activity.isWorking
    }
}
