import Foundation
import Observation

/// Browsing is independent of the computer executing the open box. A nil
/// computer filter means all connected computers; opening a box never changes
/// that filter or loses the user's search, grouping, and tag choices.
@MainActor @Observable public final class BoxBrowser {
    public var computerID: String?
    public var filter: BoxFilter = .all
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
    var browserCandidates: [ConnectedBox] { browser.candidates(in: qualifiedBoxes) }
    var browserBoxes: [ConnectedBox] { browser.results(in: browserCandidates) }
    var browserSelectionPin: ConnectedBox? {
        browser.selectionPin(in: browserCandidates, selected: active.selection.sandboxID.map { BoxLocation(connection: activeID, box: $0) })
    }
}

public enum BoxFilter: String, CaseIterable, Identifiable {
    case all = "All boxes", running = "Running", attention = "Needs attention", archived = "Archived"
    public var id: Self { self }
}

public struct BoxSwitcherGroup: Hashable {
    public let title: String
    public let rank: Int
    public func precedes(_ other: Self) -> Bool {
        rank == other.rank ? title.localizedStandardCompare(other.title) == .orderedAscending : rank < other.rank
    }
}

public extension BoxBrowser {
    func activityCounts(in candidates: [ConnectedBox]) -> (needsYou: Int, working: Int) {
        candidates.reduce(into: (needsYou: 0, working: 0)) { counts, item in
            if item.needsAttention { counts.needsYou += 1 }
            if item.activity?.isWorking == true { counts.working += 1 }
        }
    }
    func selectionPin(in candidates: [ConnectedBox], selected: BoxLocation?) -> ConnectedBox? {
        guard filter != .archived, let activityFilter, let selected else { return nil }
        return candidates.first { item in
            item.location == selected && !activityFilter.matches(item.activity ?? AgentActivity(box: item.box), box: item.box)
        }
    }
    func candidates(in items: [ConnectedBox]) -> [ConnectedBox] {
        items.filter { item in
            guard computerID == nil || computerID == item.location.connection, !item.box.isDeleted else { return false }
            let include: Bool
            switch filter {
            case .all: include = !item.box.isArchived
            case .running: include = item.power.isRunning
            case .attention: include = !item.box.isArchived && item.needsAttention
            case .archived: include = item.box.isArchived
            }
            return include && item.matches(searchText) && BoxOrganization.matches(tags: item.box.meta?.tags ?? [:], selectors: selectedTags, matchAny: matchAnyTag)
        }.sorted { Self.precedes($0, $1, sidebar: true) }
    }
    func results(in candidates: [ConnectedBox]) -> [ConnectedBox] {
        candidates.filter { item in
            filter == .archived || activityFilter.map { $0.matches(item.activity ?? AgentActivity(box: item.box), box: item.box) } != false
        }
    }
    func switcherBoxes(in items: [ConnectedBox]) -> [ConnectedBox] {
        items.filter { !$0.box.isArchived && !$0.box.isDeleted }.sorted {
            let lhs = Self.switcherGroup($0), rhs = Self.switcherGroup($1)
            if lhs != rhs { return lhs.precedes(rhs) }
            return Self.precedes($0, $1, sidebar: false)
        }
    }
    static func switcherGroup(_ item: ConnectedBox) -> BoxSwitcherGroup {
        if !item.power.isCurrent { return .init(title: "Status unknown", rank: 2) }
        if item.needsAttention { return .init(title: "Needs attention", rank: 0) }
        if item.power.isRunning { return .init(title: "Running", rank: 1) }
        if item.box.status == "Stopped" { return .init(title: "Stopped", rank: 3) }
        return .init(title: item.box.status, rank: 2)
    }
    private static func precedes(_ lhs: ConnectedBox, _ rhs: ConnectedBox, sidebar: Bool) -> Bool {
        let name = (sidebar ? lhs.box.sidebarTitle : lhs.box.displayName).localizedStandardCompare(sidebar ? rhs.box.sidebarTitle : rhs.box.displayName)
        if name != .orderedSame { return name == .orderedAscending }
        let computer = lhs.computer.localizedStandardCompare(rhs.computer)
        if computer != .orderedSame { return computer == .orderedAscending }
        if lhs.location.connection != rhs.location.connection { return lhs.location.connection < rhs.location.connection }
        return lhs.location.box < rhs.location.box
    }
}
