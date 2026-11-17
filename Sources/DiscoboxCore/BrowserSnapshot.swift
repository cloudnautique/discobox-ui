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

/// Plain per-row values, so a sidebar row never subscribes to its whole Workspace.
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

public extension Workspace {
    func rowPresentation(for box: Sandbox) -> BoxRowPresentation {
        .init(title: box.sidebarTitle, activity: activity(for: box), power: powerStatus(for: box),
              isPending: pendingBoxActions.contains(box.id), canAct: isConnected && connectionError == nil)
    }
}

/// Browser results for one set of inputs. Counts are boxes before the quick
/// filter; archived browsing ignores the quick filter.
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

    init(fleet: BrowserFleet, query: BrowserQuery) {
        // The fleet is already in sidebar order, so filtering keeps it sorted.
        candidates = fleet.items.filter { item in
            guard query.computerID == nil || query.computerID == item.location.connection else { return false }
            let include: Bool
            switch query.filter {
            case .all: include = !item.box.isArchived
            case .running: include = item.power.isRunning
            case .attention: include = !item.box.isArchived && item.needsAttention
            case .archived: include = item.box.isArchived
            }
            return include && BoxOrganization.matches(tags: item.box.meta?.tags ?? [:], selectors: query.selectedTags, matchAny: query.matchAnyTag) &&
                item.matches(query.searchText)
        }
        boxes = query.filter == .archived || query.activityFilter == nil ? candidates : candidates.filter { item in
            query.activityFilter?.matches(item.activity ?? AgentActivity(box: item.box), box: item.box) != false
        }
        needsYouCount = candidates.filter(\.needsAttention).count
        workingCount = candidates.filter { $0.activity?.isWorking == true }.count
        pending = fleet.pending
        actionableHosts = Set(fleet.hosts.filter(\.canAct).map(\.id))
    }
}

struct BrowserQuery: Equatable {
    let computerID: String?
    let filter: Workspace.BoxFilter
    let searchText: String
    let selectedTags: Set<String>
    let matchAnyTag: Bool
    let activityFilter: BoxActivityFilter?
}

/// Every box on the connected computers with its presentation derived once,
/// in sidebar order. Inputs compare cheaply: unchanged arrays share storage.
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
            return host.boxes.map { box in
                let activity = AgentActivity(box: box, pendingRequests: requests[box.id] ?? 0, reachable: host.reachable, now: host.clock.now)
                return ConnectedBox(location: .init(connection: host.id, box: box.id), computer: host.computer, box: box,
                                    needsAttention: box.matchesAttention || activity.needsYou, activity: activity,
                                    power: BoxPowerStatus(box: box, reachable: host.reachable, now: host.clock.now))
            }
        }.sorted {
            let names = $0.title.localizedStandardCompare($1.title)
            if names != .orderedSame { return names == .orderedAscending }
            if $0.computer != $1.computer { return $0.computer.localizedStandardCompare($1.computer) == .orderedAscending }
            if $0.location.box != $1.location.box { return $0.location.box < $1.location.box }
            return $0.location.connection < $1.location.connection
        }
        pending = Set(hosts.flatMap { host in host.pending.map { BoxLocation(connection: host.id, box: $0) } })
    }

    /// Attention first, then running; the keys are derived once per box.
    var switcherOrder: [ConnectedBox] {
        let waiting = Set(hosts.flatMap { host in host.approvals.map { BoxLocation(connection: host.id, box: $0.boxID) } })
        return items.filter { !$0.box.isArchived }.map { item -> (item: ConnectedBox, rank: Int, priority: Int) in
            let attention = item.needsAttention || waiting.contains(item.location)
            let rank = attention ? 0 : item.power.isRunning ? 1 : 2
            let priority: Int
            if attention { priority = 0 }
            else if item.box.isRunning { priority = 1 }
            else {
                switch item.box.status.lowercased() {
                case "starting", "pending", "awaiting source", "stopping": priority = 2
                case "stopped": priority = 3
                default: priority = 4
                }
            }
            return (ConnectedBox(location: item.location, computer: item.computer, box: item.box, needsAttention: attention,
                                 activity: item.activity, power: item.power, title: item.title), rank, priority)
        }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let names = lhs.item.box.displayName.localizedStandardCompare(rhs.item.box.displayName)
            if names != .orderedSame { return names == .orderedAscending }
            if lhs.item.computer != rhs.item.computer { return lhs.item.computer.localizedStandardCompare(rhs.item.computer) == .orderedAscending }
            if lhs.item.location.connection != rhs.item.location.connection { return lhs.item.location.connection < rhs.item.location.connection }
            // Same computer: the order Workspace.switcherBoxes gives it.
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.item.box.id < rhs.item.box.id
        }.map(\.item)
    }
}
