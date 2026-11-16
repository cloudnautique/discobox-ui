import Foundation

/// The server's composed state stays authoritative. Freshness qualifies its
/// presentation; an old Running report is not evidence that a box is stopped.
public struct BoxPowerStatus: Sendable, Equatable {
    public let isCurrent: Bool
    public let isRunning: Bool
    public let label: String
    public let message: String
    public static let maximumReportAge: TimeInterval = 120

    public init(box: Sandbox, reachable: Bool = true, now: Date = .now) {
        let reason: String?
        if !reachable {
            reason = "The connection or box list is out of date"
        } else if !box.isArchived, !box.isDeleted, let reported = box.runtime.stateReportedAt {
            // Complete runtime syncs normally arrive every 60 seconds, even
            // when power is unchanged. This is not runtimeStateChangedAt.
            if let date = ServerDate.parse(reported), abs(now.timeIntervalSince(date)) <= Self.maximumReportAge {
                reason = nil
            } else {
                reason = "The pool has not confirmed this box’s power state recently"
            }
        } else {
            // Older servers omit the timestamp. Retain their reported state
            // while the list connection is healthy; do not invent an expiry.
            reason = nil
        }
        isCurrent = reason == nil
        isRunning = isCurrent && box.isRunning
        label = isCurrent ? box.status : "Status unknown"
        message = reason.map { $0 + ". Last reported: " + box.status.lowercased() + "." } ?? ""
    }
}

public extension Workspace {
    var hasCurrentBoxInventory: Bool {
        let current = activityObservationTime
        let recentList = boxesObservedAt.map { abs(current.timeIntervalSince($0)) <= BoxPowerStatus.maximumReportAge } ?? false
        return isConnected && connectionError == nil && recentList
    }
    func powerStatus(for box: Sandbox) -> BoxPowerStatus {
        BoxPowerStatus(box: box, reachable: hasCurrentBoxInventory, now: activityObservationTime)
    }
}
