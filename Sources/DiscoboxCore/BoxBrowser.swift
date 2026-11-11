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
    public private(set) var revealLocation: BoxLocation?
    public private(set) var revealRevision = UUID()
    public func requestReveal(_ location: BoxLocation) {
        revealLocation = location
        revealRevision = UUID()
    }
    public init() {}
    public func toggleComputer(_ id: String) { computerID = computerID == id ? nil : id; archivedSelection.removeAll() }

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
    /// Counts use this set, before the quick filter, so selecting a filter does
    /// not change its own count or the other filter's count.
    var browserCandidates: [ConnectedBox] {
        sessions.filter { $0.workspace.isConnected && (browser.computerID == nil || browser.computerID == $0.id) }.flatMap { host in
            return host.workspace.sandboxes.compactMap { box -> ConnectedBox? in
                let activity = host.workspace.activity(for: box)
                let attention = box.matchesAttention || activity.needsYou
                let include: Bool
                switch browser.filter {
                case .all: include = !box.isArchived
                case .running: include = box.isRunning
                case .attention: include = !box.isArchived && attention
                case .archived: include = box.isArchived
                }
                guard include, BoxOrganization.matches(tags: box.meta?.tags ?? [:], selectors: browser.selectedTags, matchAny: browser.matchAnyTag) else { return nil }
                let item = ConnectedBox(location: .init(connection: host.id, box: box.id), computer: host.profile.displayName, box: box, needsAttention: attention, activity: activity)
                return item.matches(browser.searchText) ? item : nil
            }
        }.sorted {
            let names = $0.box.sidebarTitle.localizedStandardCompare($1.box.sidebarTitle)
            if names != .orderedSame { return names == .orderedAscending }
            if $0.computer != $1.computer { return $0.computer.localizedStandardCompare($1.computer) == .orderedAscending }
            if $0.location.box != $1.location.box { return $0.location.box < $1.location.box }
            return $0.location.connection < $1.location.connection
        }
    }
    var browserBoxes: [ConnectedBox] {
        browserCandidates.filter { item in
            browser.filter == .archived || browser.activityFilter.map { $0.matches(item.activity ?? AgentActivity(box: item.box), box: item.box) } != false
        }
    }
    /// Keep a selected box that stops matching activity visible as context,
    /// without adding it to the filter results or inflating either count.
    var browserSelectionPin: ConnectedBox? {
        guard browser.filter != .archived, let filter = browser.activityFilter, let selected = active.workspace.sandboxID else { return nil }
        return browserCandidates.first { item in
            item.location.connection == activeID && item.box.id == selected &&
                !filter.matches(item.activity ?? AgentActivity(box: item.box), box: item.box)
        }
    }
}
