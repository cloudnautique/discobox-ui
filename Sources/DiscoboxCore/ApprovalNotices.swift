import Foundation

/// Captured at delivery, independent of whichever computer is selected later.
public struct ApprovalNotice: Identifiable, Sendable, Equatable {
    public let id: String
    public let computerID: String
    public let connection: UUID
    public let item: ApprovalItem

    public enum Action: String, Sendable { case approve, deny, later, open }

    /// Refresh immediately before a mutation. A reconnected host, changed policy,
    /// failed refresh, or request answered elsewhere must never reuse a banner.
    @MainActor public func respond(_ action: Action, workspace: Workspace) async throws -> Bool {
        if action == .later { return false }
        guard workspace.isConnected, workspace.connectionID == connection else {
            throw DiscoboxError("The computer reconnected or disconnected. Open the current request in Discobox.")
        }
        try await workspace.validateApproval(item, connection: connection)
        if action == .open { return false }
        let payload: JSONValue
        if action == .deny { payload = .object([:]) }
        else {
            guard let quick = item.notificationApprovalPayload else { return false }
            payload = quick
        }
        try await workspace.answer(item, action: action.rawValue, payload: payload)
        return true
    }
}

extension ApprovalItem {
    /// Match the form's default credential approval: requested TTL and exact
    /// policy, configured credential/gate, no new rule or changed restrictions.
    /// Certificate pins, refresh tokens, delegation, and non-expiring grants
    /// need the form's explicit choices.
    public var notificationApprovalPayload: JSONValue? {
        guard kind == "credential", request["status"].string == "pending",
              request["reason"].string.isEmpty,
              ["", "use"].contains(request["purpose"].string) else { return nil }
        let ttl = request["grantTTLSeconds"]
        guard ttl == .null || ttl.number != nil else { return nil }
        let seconds = ttl.number ?? 3600
        guard seconds.isFinite, seconds > 0, seconds.rounded() == seconds, seconds < Double(Int.max) else { return nil }
        var body: [String: JSONValue] = ["grantTTLSeconds": .number(seconds)]
        if request["policy"] != .null { body["policy"] = request["policy"] }
        return .object(body)
    }
}

/// In-memory deduplication only. No credentials or approval policies are written
/// into Notification Center, preferences, or a second background polling loop.
@MainActor public final class ApprovalNoticeInbox {
    public struct Changes {
        public var added: [ApprovalNotice] = []
        public var removed: [String] = []
    }
    private var entries: [String: ApprovalNotice] = [:]
    private var inFlight: Set<String> = []
    public init() {}
    public func notice(_ id: String) -> ApprovalNotice? { entries[id] }
    public func claim(_ id: String) -> ApprovalNotice? {
        guard let entry = entries[id], inFlight.insert(id).inserted else { return nil }
        return entry
    }
    public func finish(_ id: String) { inFlight.remove(id) }
    public func update(computerID: String, connection: UUID, items: [ApprovalItem]) -> Changes {
        var changes = Changes()
        let existing = entries.values.filter { $0.computerID == computerID }
        for entry in existing where entry.connection != connection || !items.contains(entry.item) {
            entries.removeValue(forKey: entry.id)
            changes.removed.append(entry.id)
        }
        for item in items where !item.id.isEmpty && item.request["status"].string == "pending" {
            if entries.values.contains(where: { $0.computerID == computerID && $0.connection == connection && $0.item == item }) { continue }
            let entry = ApprovalNotice(id: "approval-" + UUID().uuidString, computerID: computerID, connection: connection, item: item)
            entries[entry.id] = entry; changes.added.append(entry)
        }
        return changes
    }
    public func reset() -> [String] {
        let ids = Array(entries.keys)
        entries.removeAll(); inFlight.removeAll()
        return ids
    }
}
