import Foundation
import Observation

/// Explicit box lifecycle and creation operations. No selected-computer lookup or automatic mutation retry.
@MainActor @Observable public final class BoxCommands {
    private let pools: PoolCommands
    let connectionState: ConnectionStore
    let inventory: BoxInventoryStore
    let selection: BoxSelectionStore
    let pending: PendingBoxOperations
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored var refresh: () async -> Void = {}
    init(connection: ConnectionStore, inventory: BoxInventoryStore, selection: BoxSelectionStore, pending: PendingBoxOperations, pools: PoolCommands, now: @escaping () -> Date) {
        connectionState = connection; self.inventory = inventory; self.selection = selection; self.pending = pending; self.pools = pools; self.now = now
    }
    public struct PurgeResult: Sendable {
        public struct Failure: Sendable {
            public let boxID: String
            public let message: String
        }
        public let purged: [String]
        public let failures: [Failure]
    }
    public func performBoxAction(_ action: BoxAction, boxID: String, connection: UUID, name: String = "", refreshAfter: Bool = true, onAccepted: () -> Void = {}, beforeRequest: () -> Void = {}) async throws {
        guard connection == connectionState.connectionID, let client = connectionState.client, let projectID = connectionState.projectID,
              let box = inventory.sandboxes.first(where: { $0.id == boxID }), action.isAvailable(for: box) else {
            throw DiscoboxError("This action is no longer available. Refresh the box and try again.")
        }
        guard !pending.pendingBoxActions.contains(boxID) else { throw DiscoboxError("An action is already in progress for this box.") }
        guard !pending.clearingPools.contains(box.poolId ?? "") else { throw DiscoboxError("This pool is clearing its caches. Wait for cleanup to finish.") }
        selection.invalidateCachedBox(boxID)
        pending.pendingBoxActions.insert(boxID)
        defer { if connection == connectionState.connectionID { pending.pendingBoxActions.remove(boxID) } }
        if selection.sandboxID == boxID && [.stop, .archive, .unarchive, .purge, .upgrade, .repair].contains(action) { selection.clearSelection() }
        beforeRequest()
        _ = try await client.perform(.init(.boxAction, projectID: projectID, sandboxID: boxID, name: name, action: action.rawValue))
        guard connection == connectionState.connectionID else { return }
        if action == .purge {
            inventory.acknowledgePurge(boxID)
        }
        // Avoid reconnecting to a box after an explicit stop/archive/restore.
        if selection.sandboxID == boxID && [.stop, .archive, .unarchive, .purge, .upgrade, .repair].contains(action) { selection.clearSelection() }
        // The mutation is acknowledged. UI completion must not wait for an
        // unrelated inventory/details refresh or dismiss a later presentation.
        onAccepted()
        if refreshAfter { await refresh() }
    }

    public func purgeArchivedBoxes(_ boxIDs: [String], connection: UUID, progress: (Int, Int) -> Void = { _, _ in }) async throws -> PurgeResult {
        var seen: Set<String> = []
        let ids = boxIDs.filter { seen.insert($0).inserted }
        guard connection == connectionState.connectionID, !ids.isEmpty,
              ids.allSatisfy({ id in inventory.sandboxes.contains { $0.id == id && BoxAction.purge.isAvailable(for: $0) } && !pending.pendingBoxActions.contains(id) }) else {
            throw DiscoboxError("The selection changed or contains a box that can no longer be purged. Refresh Archived and select again.")
        }
        var purged: [String] = []
        var failures: [PurgeResult.Failure] = []
        for (index, id) in ids.enumerated() {
            guard connection == connectionState.connectionID, !Task.isCancelled else {
                failures += ids[index...].map { .init(boxID: $0, message: "Not attempted: the connection changed or the operation was cancelled.") }
                break
            }
            do {
                try await performBoxAction(.purge, boxID: id, connection: connection, refreshAfter: false)
                purged.append(id)
            } catch {
                failures.append(.init(boxID: id, message: error.localizedDescription))
            }
            progress(index + 1, ids.count)
        }
        if connection == connectionState.connectionID, !Task.isCancelled { await refresh() }
        return PurgeResult(purged: purged, failures: failures)
    }

    @discardableResult public func createBox(harness: String, repository: String, prompt: String = "", poolID: String? = nil, connection: UUID? = nil, credentials: [LaunchCredential] = [], discoboxAPI: Bool = false) async throws -> Sandbox {
        guard let client = connectionState.client, let projectID = connectionState.projectID else { throw DiscoboxError("Connect to a server first.") }
        guard connection == nil || connection == connectionState.connectionID else { throw DiscoboxError("The destination computer reconnected. Review the new box settings again.") }
        let credentialPayload = try LaunchCredential.payload(credentials)
        let current = connectionState.revision
        await pools.refreshResources(force: true)
        guard current == connectionState.revision, !Task.isCancelled else { throw CancellationError() }
        let destination = poolID ?? pools.resources.defaultPoolID
        if let destination, !destination.isEmpty {
            guard !pending.clearingPools.contains(destination) else { throw DiscoboxError("This pool is clearing its caches. Wait for cleanup to finish.") }
            if pools.resources.error == nil && !pools.resources.pools.contains(where: { $0.id == destination }) {
                throw DiscoboxError("The selected pool is no longer available. Choose a pool again.")
            }
            let health = pools.resources.health(destination, now: now())
            guard health.canCreate else { throw DiscoboxError(health.messages.joined(separator: " ")) }
        }
        do {
            let box = try await client.decode(.init(.createBox, projectID: projectID, harnessID: harness, repository: repository, prompt: prompt, payload: credentialPayload, poolID: destination, discoboxAPI: discoboxAPI ? true : nil), as: Sandbox.self)
            guard current == connectionState.revision else { throw CancellationError() }
            await refresh()
            guard current == connectionState.revision else { throw CancellationError() }
            // Keep the accepted box selectable even if this first list refresh
            // failed or has not included it yet.
            inventory.includeCreated(box)
            await selection.selectBox(box.id)
            guard current == connectionState.revision else { throw CancellationError() }
            return inventory.sandboxes.first(where: { $0.id == box.id }) ?? box
        } catch {
            if current == connectionState.revision { await refresh() }
            throw error
        }
    }


}
