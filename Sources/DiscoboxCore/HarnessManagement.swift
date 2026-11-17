import Foundation
import Observation

@MainActor @Observable public final class HarnessManagement {
    public let connectionState: ConnectionStore
    public let inventory: BoxInventoryStore
    private let service: HarnessService
    private let initialBoxID: String?
    public let harnessID: String
    public let connection: UUID
    public private(set) var details: JSONValue = .null
    public private(set) var review: JSONValue = .null
    public private(set) var result: JSONValue = .null
    public private(set) var error: String?
    public private(set) var busy = false
    public private(set) var boxID = ""
    public private(set) var reviewRevision = 0
    private var revision = UUID()
    private var closed = false
    public init(connection: ConnectionStore, inventory: BoxInventoryStore, service: HarnessService, sourceBoxID: String?, harnessID: String) {
        self.connectionState = connection; self.inventory = inventory; self.service = service; initialBoxID = sourceBoxID
        self.harnessID = harnessID; self.connection = connection.connectionID
    }
    public var validConnection: Bool { !closed && connectionState.isConnected && connectionState.connectionID == connection }
    public var changes: JSONValue { review["changes"] }
    public var canSave: Bool {
        return validConnection && !busy && HarnessCapture.canSave(changes)
    }
    public var canDiscard: Bool { validConnection && !busy && changes["state"].string == "pending" && !changes["candidateId"].string.isEmpty }
    public var boxes: [Sandbox] {
        inventory.sandboxes.filter { $0.config.harnessConfigId == harnessID && $0.isRunning }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    public func selectBox(_ id: String) {
        guard id != boxID, !busy else { return }
        boxID = id; review = .null; result = .null; error = nil; revision = UUID()
    }
    public func requestReview(box id: String) {
        guard validConnection, !busy else { return }
        selectBox(id)
        reviewRevision += 1
    }
    public func load() async {
        guard validConnection, !busy else { return }
        busy = true; error = nil
        let token = revision
        defer { busy = false }
        do {
            let value = try await perform(.harnessDetails)
            guard validConnection, token == revision else { return }
            guard value["harness"]["id"].string == harnessID else { throw DiscoboxError("The harness changed. Close and reopen its settings.") }
            details = value
            if boxID.isEmpty {
                let selected = boxes.first { $0.id == initialBoxID } ?? boxes.first
                if let selected { boxID = selected.id }
            }
        } catch { if validConnection, token == revision { self.error = error.localizedDescription } }
    }
    public func refreshPreview(includeSharedDetails: Bool = true) async {
        guard validConnection, !busy, !boxID.isEmpty else { return }
        let source = boxID, token = revision
        busy = true; error = nil; review = .null
        defer { busy = false }
        do {
            let metadata = includeSharedDetails ? try await perform(.harnessDetails) : details
            if includeSharedDetails, metadata["harness"]["id"].string != harnessID { throw DiscoboxError("The shared harness changed. Reopen its settings.") }
            let value = try await perform(.harnessChanges, box: source)
            guard validConnection, token == revision, boxID == source else { return }
            guard HarnessCapture.accepts(value["changes"], harnessID: harnessID), !value["fingerprint"].string.isEmpty else { throw DiscoboxError("Invalid harness preview. Refresh and try again.") }
            if includeSharedDetails { details = metadata }
            review = value; result = .null
        } catch { if validConnection, token == revision { self.error = error.localizedDescription } }
    }
    public func answer(save: Bool) async {
        guard save ? canSave : canDiscard else { return }
        let source = boxID, token = revision
        let payload: JSONValue = .object(["candidateId": changes["candidateId"], "fingerprint": review["fingerprint"]])
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await perform(save ? .saveHarnessChanges : .discardHarnessChanges, box: source, payload: payload)
            guard validConnection, token == revision, boxID == source else { return }
            if save {
                guard value["harnessConfigId"].string == harnessID,
                      value["candidateId"] == payload["candidateId"], !value["state"].string.isEmpty else {
                    throw DiscoboxError("The save receipt did not match this harness and candidate. Refresh the preview to check the result.")
                }
            }
            result = value; review = .null
        } catch {
            if validConnection, token == revision {
                self.error = error.localizedDescription
                // Re-open the review after any ambiguous result. Retrying the
                // old button must not capture a different login or rotate twice.
                review = .null
            }
        }
    }
    public func close() { closed = true; revision = UUID() }
    private func perform(_ operation: BridgeRequest.Operation, box: String? = nil, payload: JSONValue? = nil) async throws -> JSONValue {
        guard validConnection else { throw DiscoboxError("This computer reconnected. Close and reopen harness management.") }
        switch operation {
        case .harnessDetails: return try await service.details(harness: harnessID)
        case .harnessChanges: return try await service.changes(harness: harnessID, box: box ?? "")
        case .saveHarnessChanges: return try await service.save(harness: harnessID, box: box ?? "", payload: payload ?? .null)
        case .discardHarnessChanges: return try await service.discard(harness: harnessID, box: box ?? "", payload: payload ?? .null)
        default: throw DiscoboxError("Unsupported harness operation.")
        }
    }
}
