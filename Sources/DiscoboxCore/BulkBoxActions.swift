import Foundation

public extension BoxAction {
    static var bulkActions: [Self] { [.start, .stop, .archive, .unarchive, .upgrade, .repair] }
}

public extension Workspace {
    struct BulkActionResult: Sendable {
        public let accepted: [String]
        public let failures: [PurgeResult.Failure]
    }

    /// Capture one computer/generation and a complete manifest before writing.
    /// Recheck each box, never retry a mutation, and refresh inventory once.
    func performBoxActions(_ action: BoxAction, boxIDs: [String], connection: UUID,
                           progress: (Int, Int) -> Void = { _, _ in },
                           beforeRequest: (String) -> Void = { _ in },
                           onAccepted: (String) -> Void = { _ in }) async throws -> BulkActionResult {
        var seen: Set<String> = []
        let ids = boxIDs.filter { seen.insert($0).inserted }
        guard BoxAction.bulkActions.contains(action), connection == connectionID, !ids.isEmpty,
              ids.allSatisfy({ id in
                  sandboxes.contains { $0.id == id && action.isAvailable(for: $0) && !clearingPools.contains($0.poolId ?? "") } && !pendingBoxActions.contains(id)
              }) else { throw DiscoboxError("The selection or connection changed. Review the selected boxes again.") }
        var accepted: [String] = []
        var failures: [PurgeResult.Failure] = []
        for (index, id) in ids.enumerated() {
            guard connection == connectionID, !Task.isCancelled else {
                failures += ids[index...].map { .init(boxID: $0, message: "Not attempted: the connection changed or the operation was cancelled.") }
                break
            }
            do {
                var recorded = false
                try await performBoxAction(action, boxID: id, connection: connection, refreshAfter: false,
                    onAccepted: { recorded = true; onAccepted(id) }, beforeRequest: { beforeRequest(id) })
                if recorded { accepted.append(id) }
                else { failures.append(.init(boxID: id, message: "The connection changed. Check this box’s current state before retrying.")) }
            } catch { failures.append(.init(boxID: id, message: error.localizedDescription)) }
            progress(index + 1, ids.count)
        }
        if connection == connectionID, !Task.isCancelled { await refresh() }
        return .init(accepted: accepted, failures: failures)
    }
}
