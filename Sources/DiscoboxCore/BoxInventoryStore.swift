import Foundation
import Observation

@MainActor @Observable
public final class BoxInventoryStore {
    public private(set) var sandboxes: [Sandbox] = []
    public private(set) var boxesObservedAt: Date?
    public private(set) var lastRefresh: Date?
    @ObservationIgnored private var listRequest = LatestRequest()
    @ObservationIgnored private var confirmedPurges: Set<String> = []
    @ObservationIgnored private var metadata: [Sandbox] = []
    @ObservationIgnored private var eventRows: [String: ProjectBoxEvent] = [:]
    @ObservationIgnored private var eventDeletes: Set<String> = []
    @ObservationIgnored private var completeReplay = false
    // A create response can arrive before its event on the live stream.
    @ObservationIgnored private var awaitingCreateEvent: [String: Sandbox] = [:]
    @ObservationIgnored private var listingEpoch: UUID?
    private(set) var replayingReset = false

    // Render one snapshot per delivered batch, retaining the listing order.
    private func publish() {
        let listed = Set(metadata.map(\.id))
        var rows = metadata.compactMap { box -> Sandbox? in
            guard !confirmedPurges.contains(box.id), !eventDeletes.contains(box.id) else { return nil }
            if let event = eventRows[box.id] { return event.applying(to: box) }
            if awaitingCreateEvent[box.id] != nil { return box }
            return completeReplay || box.isDeleted ? nil : box
        }
        for id in eventRows.keys.filter({ !listed.contains($0) && !confirmedPurges.contains($0) }).sorted() {
            if let row = eventRows[id] { rows.append(row.applying(to: nil)) }
        }
        for id in awaitingCreateEvent.keys.sorted() where !listed.contains(id) {
            if let box = awaitingCreateEvent[id] { rows.append(box) }
        }
        if rows != sandboxes { sandboxes = rows }
    }

    func apply(_ changes: [ProjectEventReplay.Change]) -> Bool {
        listingEpoch = nil
        var changed = false, hydrate = false
        for change in changes {
            switch change {
            case .none: continue
            case .stale: replayingReset = true; continue
            case .replace(let rows):
                awaitingCreateEvent.removeAll()
                eventRows = rows; eventDeletes = []; completeReplay = true; replayingReset = false
                hydrate = !Set(rows.keys).isSubset(of: Set(metadata.map(\.id)))
            case .update(let event):
                awaitingCreateEvent.removeValue(forKey: event.sandboxId)
                if eventRows[event.sandboxId] == nil && !metadata.contains(where: { $0.id == event.sandboxId }) { hydrate = true }
                eventRows[event.sandboxId] = event
                eventDeletes.remove(event.sandboxId)
            case .delete(let id):
                awaitingCreateEvent.removeValue(forKey: id)
                eventRows.removeValue(forKey: id)
                if !completeReplay { eventDeletes.insert(id) }
            }
            changed = true
        }
        if changed { publish() }
        return hydrate
    }

    func resumeListing() {
        // Keep the visible snapshot until the next successful database read.
        listingEpoch = UUID()
    }
    public init() {}
    func refresh(using connection: ConnectionStore, now: () -> Date) async throws -> UUID? {
        let access = try connection.capture(), request = listRequest.begin()
        let epoch = listingEpoch
        do {
            try await connection.prepareTransport()
            guard access.isCurrent, listRequest.owns(request) else { return nil }
            let data = try await access.perform(.init(.sandboxes, projectID: access.scope.project))
            let result = try JSONDecoder().decode(SandboxesResponse.self, from: data)
            guard listRequest.owns(request) else { return nil }
            if let epoch, epoch == listingEpoch {
                awaitingCreateEvent.removeAll()
                eventRows = [:]; eventDeletes = []; completeReplay = false; replayingReset = false
            }
            metadata = result.sandboxes ?? []
            boxesObservedAt = now()
            publish()
            return request
        } catch {
            guard access.isCurrent, listRequest.owns(request) else { return nil }
            throw error
        }
    }
    func complete(_ request: UUID, at date: Date) {
        if listRequest.owns(request) { lastRefresh = date }
    }
    func acknowledgePurge(_ id: String) {
        awaitingCreateEvent.removeValue(forKey: id)
        confirmedPurges.insert(id)
        sandboxes.removeAll { $0.id == id }
    }
    func includeCreated(_ box: Sandbox) {
        if completeReplay && eventRows[box.id] == nil { awaitingCreateEvent[box.id] = box }
        if !metadata.contains(where: { $0.id == box.id }) { metadata.append(box) }
        if !sandboxes.contains(where: { $0.id == box.id }) { sandboxes.append(box) }
    }
    func reset() {
        awaitingCreateEvent.removeAll()
        listRequest.invalidate()
        listingEpoch = nil
        eventRows.removeAll()
        eventDeletes.removeAll()
        completeReplay = false
        replayingReset = false
        metadata.removeAll()
        confirmedPurges.removeAll()
        sandboxes = []
        boxesObservedAt = nil
        lastRefresh = nil
    }
}
