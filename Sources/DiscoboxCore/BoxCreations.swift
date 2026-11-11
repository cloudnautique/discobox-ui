import Foundation

/// Temporary visibility for a box the user just created, independent of the
/// browser's filters. A launch is always scoped to its original connection.
public struct BoxCreation: Identifiable, Sendable {
    public var id: BoxLocation { item.location }
    public let connection: UUID
    public let item: ConnectedBox
    public enum Phase: String, Sendable { case starting, failed, ready }
    public var phase: Phase {
        let runtime = item.box.runtime
        if item.box.isRunning { return .ready }
        if item.box.matchesAttention || runtime.displayState == "stopped" ||
            (runtime.displayState == nil && runtime.state == "ready" && runtime.runtimeState == "stopped") { return .failed }
        return item.box.isRunning ? .ready : .starting
    }
    public var message: String {
        if let error = item.box.runtime.errorMessage, !error.isEmpty { return error }
        switch phase {
        case .starting: return item.box.preparationStatus ?? "Starting…"
        case .failed: return "Startup stopped. Open the box to review its status."
        case .ready: return "Running · outside your current filters"
        }
    }
}

public extension Connections {
    var creationPins: [BoxCreation] {
        creations.compactMap { creation in
            guard let host = session(creation.id.connection), host.workspace.isConnected,
                  host.workspace.connectionID == creation.connection else { return nil }
            let box = host.workspace.sandboxes.first { $0.id == creation.id.box } ?? creation.item.box
            guard !box.isArchived else { return nil }
            return BoxCreation(connection: creation.connection,
                               item: .init(location: creation.id, computer: host.profile.displayName, box: box, needsAttention: box.matchesAttention))
        }
    }

    /// Uses the existing inventory refresh. No extra requests or launch polling.
    func reconcileCreations() {
        guard !creations.isEmpty else { return }
        let visible = Set(browserBoxes.map(\.location))
        creations = creationPins.filter { creation in
            guard let host = session(creation.id.connection), host.workspace.sandboxes.contains(where: { $0.id == creation.id.box }) else { return false }
            if creation.phase == .ready && visible.contains(creation.id) {
                if activeID == host.id && host.workspace.sandboxID == creation.id.box { browser.requestReveal(creation.id) }
                return false
            }
            return true
        }
    }

    func dismissCreation(_ location: BoxLocation) { creations.removeAll { $0.id == location } }

    func revealCreatedBox(_ location: BoxLocation) async {
        guard let creation = creationPins.first(where: { $0.id == location }),
              let host = session(location.connection) else { return }
        let box = creation.item.box
        if browser.computerID != nil && browser.computerID != host.id { browser.computerID = host.id }
        if !browserBoxes.contains(where: { $0.location == location }) {
            if browser.filter == .archived || (browser.filter == .running && !box.isRunning) || (browser.filter == .attention && !box.matchesAttention) {
                browser.filter = box.isRunning ? .running : .all
            }
            if !creation.item.matches(browser.searchText) { browser.searchText = "" }
            if !BoxOrganization.matches(tags: box.meta?.tags ?? [:], selectors: browser.selectedTags, matchAny: browser.matchAnyTag) { browser.selectedTags.removeAll() }
            if browser.activityFilter?.matches(host.workspace.activity(for: box), box: box) == false { browser.activityFilter = nil }
        }
        await selectBox(location)
        guard host.workspace.connectionID == creation.connection else { return }
        browser.requestReveal(location)
        reconcileCreations()
    }
}
