import Foundation
import Observation

/// Browsing is independent of the computer executing the open box. A nil
/// computer filter means all connected computers; opening a box never changes
/// that filter or loses the user's search, grouping, and tag choices.
@MainActor @Observable public final class BoxBrowser {
    public var computerID: String?
    public var filter: Workspace.BoxFilter = .all
    public var searchText = ""
    public var selectedTags: Set<String> = []
    public var matchAnyTag = false
    public var activityFilter: BoxActivityFilter?
    public var archivedSelection: Set<BoxLocation> = []
    public var selectedBoxes: Set<BoxLocation> = []
    public private(set) var revealLocation: BoxLocation?
    public private(set) var revealRevision = UUID()
    public func requestReveal(_ location: BoxLocation) {
        revealLocation = location
        revealRevision = UUID()
    }
    public init() {}
    @ObservationIgnored private var fleetMemo: BrowserFleet?
    @ObservationIgnored private var snapshotMemo: (fleet: Int, query: BrowserQuery, snapshot: BrowserSnapshot)?
    var query: BrowserQuery {
        .init(computerID: computerID, filter: filter, searchText: searchText, selectedTags: selectedTags, matchAnyTag: matchAnyTag, activityFilter: activityFilter)
    }
    /// Callers read every input first, so Observation tracks them; the memo
    /// only avoids re-deriving and re-sorting when those inputs are unchanged.
    func fleet(_ hosts: [BrowserFleet.Host]) -> BrowserFleet {
        if let fleetMemo, fleetMemo.hosts == hosts { return fleetMemo }
        let fleet = BrowserFleet(hosts: hosts, revision: (fleetMemo?.revision ?? 0) + 1)
        fleetMemo = fleet
        return fleet
    }
    func snapshot(hosts: [BrowserFleet.Host], query: BrowserQuery) -> BrowserSnapshot {
        let fleet = fleet(hosts)
        if let snapshotMemo, snapshotMemo.fleet == fleet.revision, snapshotMemo.query == query { return snapshotMemo.snapshot }
        let snapshot = BrowserSnapshot(fleet: fleet, query: query)
        snapshotMemo = (fleet.revision, query, snapshot)
        return snapshot
    }
    public func toggleComputer(_ id: String) { computerID = computerID == id ? nil : id; archivedSelection.removeAll(); selectedBoxes.removeAll() }

    public func selectBoxes(_ ids: Set<BoxLocation>) {
        let added = ids.subtracting(selectedBoxes)
        let target = added.sorted { $0.connection == $1.connection ? $0.box < $1.box : $0.connection < $1.connection }.first?.connection ?? ids.first?.connection
        selectedBoxes = Set(ids.filter { $0.connection == target })
    }

    /// Keep the existing bulk-purge contract: one captured host at a time,
    /// even when archives from several hosts are visible together.
    public func selectArchives(_ ids: Set<BoxLocation>) {
        let added = ids.subtracting(archivedSelection)
        let target = added.sorted { $0.connection == $1.connection ? $0.box < $1.box : $0.connection < $1.connection }.first?.connection
            ?? ids.first?.connection
        archivedSelection = Set(ids.filter { $0.connection == target })
    }
}

public extension Connections {
    /// Reading this registers dependencies on every input (each connected
    /// workspace's boxes, approvals, aging clock, reachability and pending
    /// actions, and the browser's scope), even when the memo is reused.
    var browserSnapshot: BrowserSnapshot { browser.snapshot(hosts: browserHosts, query: browser.query) }
    /// Counts use this set, before the quick filter, so selecting a filter does
    /// not change its own count or the other filter's count.
    var browserCandidates: [ConnectedBox] { browserSnapshot.candidates }
    var browserBoxes: [ConnectedBox] { browserSnapshot.boxes }
    /// Keep a selected box that stops matching activity visible as context,
    /// without adding it to the filter results or inflating either count.
    var browserSelectionPin: ConnectedBox? {
        guard browser.filter != .archived, let filter = browser.activityFilter, let selected = active.workspace.sandboxID else { return nil }
        let id = activeID
        return browserCandidates.first { item in
            item.location.connection == id && item.box.id == selected &&
                !filter.matches(item.activity ?? AgentActivity(box: item.box), box: item.box)
        }
    }
    internal var browserFleet: BrowserFleet { browser.fleet(browserHosts) }
    private var browserHosts: [BrowserFleet.Host] {
        sessions.filter { $0.workspace.isConnected }.map { host in
            let workspace = host.workspace
            return .init(id: host.id, computer: host.profile.displayName, boxes: workspace.sandboxes, approvals: workspace.approvals,
                         clock: workspace.activityClock, reachable: workspace.hasCurrentBoxInventory,
                         canAct: workspace.connectionError == nil, pending: workspace.pendingBoxActions)
        }
    }
}
