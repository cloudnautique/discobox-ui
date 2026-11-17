import Foundation

/// Activity and power ages compare server timestamps with this rather than the
/// wall clock. A refresh advances it when any report's two-minute freshness (or
/// the box list's) would differ from its age at the previous tick, so derived
/// values equal those computed at that refresh, exactly as when every refresh
/// re-evaluated with `now`. Otherwise it advances at most once a minute: steady
/// refreshes of unchanged reports publish nothing, and a box added between
/// refreshes is never judged against a clock more than a minute old.
public struct ActivityClock: Equatable, Sendable {
    public let now: Date
    public let inventoryIsCurrent: Bool
    public static let heartbeat: TimeInterval = 60
    public init(now: Date = .distantPast, inventoryIsCurrent: Bool = false) {
        self.now = now; self.inventoryIsCurrent = inventoryIsCurrent
    }
    public func advanced(to current: Date, inventoryObservedAt: Date?, boxes: [Sandbox]) -> ActivityClock {
        advanced(to: current, inventoryObservedAt: inventoryObservedAt, reportDates: Self.reportDates(boxes))
    }
    public func advanced(to current: Date, inventoryObservedAt: Date?, reportDates: [Date]) -> ActivityClock {
        let next = ActivityClock(now: current, inventoryIsCurrent: inventoryObservedAt.map { Self.isFresh($0, at: current) } ?? false)
        if next.inventoryIsCurrent != inventoryIsCurrent || current < now || current.timeIntervalSince(now) >= Self.heartbeat { return next }
        return reportDates.contains { Self.isFresh($0, at: now) != Self.isFresh($0, at: current) } ? next : self
    }
    /// The report timestamps whose freshness the clock tracks.
    static func reportDates(_ boxes: [Sandbox]) -> [Date] {
        boxes.flatMap { [$0.runtime.stateReportedAt ?? "", ($0.runtime.agentStatus ?? .null)["observedAt"].string].compactMap(ServerDate.parse) }
    }
    /// The rule `AgentActivity` and `BoxPowerStatus` apply to these timestamps.
    static func isFresh(_ date: Date, at now: Date) -> Bool { abs(now.timeIntervalSince(date)) <= BoxPowerStatus.maximumReportAge }
}

/// Plain per-row values, so a sidebar row never subscribes to its whole session.
public struct BoxRowPresentation: Equatable, Sendable {
    public let title: String
    public let activity: AgentActivity
    public let power: BoxPowerStatus
    public let isPending: Bool
    public let canAct: Bool
    public init(title: String, activity: AgentActivity, power: BoxPowerStatus, isPending: Bool, canAct: Bool) {
        self.title = title; self.activity = activity; self.power = power; self.isPending = isPending; self.canAct = canAct
    }
}

public extension ConnectionSession {
    func rowPresentation(for box: Sandbox) -> BoxRowPresentation {
        .init(title: box.sidebarTitle, activity: activity(for: box), power: powerStatus(for: box),
              isPending: pending.pendingBoxActions.contains(box.id), canAct: connectionState.isConnected && connectionState.connectionError == nil)
    }
}

/// Browser results for one set of inputs, from BoxBrowser's selectors. Counts
/// are boxes before the quick filter; archived browsing ignores it.
public struct BrowserSnapshot: Sendable {
    public let candidates: [ConnectedBox]
    public let boxes: [ConnectedBox]
    public let needsYouCount: Int
    public let workingCount: Int
    let pending: Set<BoxLocation>
    let actionableHosts: Set<String>
    public func row(_ item: ConnectedBox) -> BoxRowPresentation {
        .init(title: item.title, activity: item.activity ?? AgentActivity(box: item.box), power: item.power,
              isPending: pending.contains(item.location), canAct: actionableHosts.contains(item.location.connection))
    }
    @MainActor init(browser: BoxBrowser, fleet: BrowserFleet) {
        candidates = browser.candidates(in: fleet.items)
        boxes = browser.results(in: candidates)
        (needsYouCount, workingCount) = browser.activityCounts(in: candidates)
        pending = fleet.pending
        actionableHosts = Set(fleet.hosts.filter(\.canAct).map(\.id))
    }
}

struct BrowserQuery: Equatable {
    let computerID: String?
    let filter: BoxFilter
    let searchText: String
    let selectedTags: Set<String>
    let matchAnyTag: Bool
    let activityFilter: BoxActivityFilter?
}

/// Every box on the connected computers with its presentation derived once.
/// Inputs compare cheaply: unchanged arrays share storage.
struct BrowserFleet {
    struct Host: Equatable {
        let id: String
        let computer: String
        let boxes: [Sandbox]
        let approvals: [ApprovalItem]
        let clock: ActivityClock
        let reachable: Bool
        let canAct: Bool
        let pending: Set<String>
    }
    let hosts: [Host]
    let items: [ConnectedBox]
    let pending: Set<BoxLocation>
    let revision: Int

    init(hosts: [Host], revision: Int) {
        self.hosts = hosts; self.revision = revision
        items = hosts.flatMap { host -> [ConnectedBox] in
            let requests = Dictionary(host.approvals.map { ($0.boxID, 1) }, uniquingKeysWith: +)
            return host.boxes.filter { !$0.isDeleted }.map { box in
                let activity = AgentActivity(box: box, pendingRequests: requests[box.id] ?? 0, reachable: host.reachable, now: host.clock.now)
                return ConnectedBox(location: .init(connection: host.id, box: box.id), computer: host.computer, box: box,
                                    needsAttention: box.matchesAttention || activity.needsYou, activity: activity,
                                    power: BoxPowerStatus(box: box, reachable: host.reachable, now: host.clock.now))
            }
        }
        pending = Set(hosts.flatMap { host in host.pending.map { BoxLocation(connection: host.id, box: $0) } })
    }
}
