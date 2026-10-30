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
    public var archivedSelection: Set<BoxLocation> = []
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
    var browserBoxes: [ConnectedBox] {
        sessions.filter { $0.workspace.isConnected && (browser.computerID == nil || browser.computerID == $0.id) }.flatMap { host in
            let waiting = Set(host.workspace.approvals.map(\.boxID))
            return host.workspace.sandboxes.compactMap { box -> ConnectedBox? in
                let attention = box.matchesAttention || waiting.contains(box.id)
                let include: Bool
                switch browser.filter {
                case .all: include = !box.isArchived
                case .running: include = box.isRunning
                case .attention: include = !box.isArchived && attention
                case .archived: include = box.isArchived
                }
                guard include, BoxOrganization.matches(tags: box.meta?.tags ?? [:], selectors: browser.selectedTags, matchAny: browser.matchAnyTag) else { return nil }
                let item = ConnectedBox(location: .init(connection: host.id, box: box.id), computer: host.profile.displayName, box: box, needsAttention: attention)
                return item.matches(browser.searchText) ? item : nil
            }
        }.sorted {
            func rank(_ item: ConnectedBox) -> Int { item.needsAttention ? 0 : item.box.isRunning ? 1 : 2 }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            let names = $0.box.displayName.localizedStandardCompare($1.box.displayName)
            if names != .orderedSame { return names == .orderedAscending }
            if $0.computer != $1.computer { return $0.computer.localizedStandardCompare($1.computer) == .orderedAscending }
            return $0.location.box < $1.location.box
        }
    }
}
