import Foundation
import Observation

/// Pool resource reads and cache cleanup share the mutation interlock with box commands.
@MainActor @Observable public final class PoolCommands {
    public private(set) var resources = PoolResources()
    public private(set) var poolCleanupStatus: [String: String] = [:]
    let connectionState: ConnectionStore
    let inventory: BoxInventoryStore
    let selection: BoxSelectionStore
    let pending: PendingBoxOperations
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored var refresh: () async -> Void = {}
    init(connection: ConnectionStore, inventory: BoxInventoryStore, selection: BoxSelectionStore, pending: PendingBoxOperations, now: @escaping () -> Date) {
        connectionState = connection; self.inventory = inventory; self.selection = selection; self.pending = pending; self.now = now
    }
    func reset() { resources.cancel(); resources = PoolResources(); poolCleanupStatus = [:] }
    public struct CacheClearResult: Decodable, Sendable { public let stoppedSandboxIds: [String] }
    public func clearPoolCache(poolID: String, connection: UUID, beforeRequest: ([String]) -> Void = { _ in }) async throws -> CacheClearResult {
        guard connection == connectionState.connectionID, let client = connectionState.client, let projectID = connectionState.projectID, connectionState.isConnected,
              resources.pools.contains(where: { $0.id == poolID }), !pending.clearingPools.contains(poolID) else {
            throw DiscoboxError("This pool or connection changed. Reopen Resources before clearing caches.")
        }
        let boxes = inventory.sandboxes.filter { $0.poolId == poolID }.map(\.id)
        guard pending.pendingBoxActions.isDisjoint(with: boxes) else { throw DiscoboxError("A box action is in progress on this pool.") }
        pending.clearingPools.insert(poolID); pending.pendingBoxActions.formUnion(boxes)
        poolCleanupStatus[poolID] = "Stopping boxes and clearing caches… You can close Resources while cleanup continues."
        for id in boxes { selection.invalidateCachedBox(id) }
        if boxes.contains(selection.sandboxID ?? "") { selection.clearSelection() }
        beforeRequest(boxes)
        defer {
            if connection == connectionState.connectionID {
                pending.clearingPools.remove(poolID); pending.pendingBoxActions.subtract(boxes)
            }
        }
        do {
            let result = try await client.decode(.init(.clearPoolCache, projectID: projectID, poolID: poolID), as: CacheClearResult.self)
            guard connection == connectionState.connectionID else { throw CancellationError() }
            poolCleanupStatus[poolID] = "Caches cleared. \(result.stoppedSandboxIds.count) boxes stopped. Start them when you are ready."
            resources.invalidate(poolID, at: now())
            await refresh()
            guard connection == connectionState.connectionID else { throw CancellationError() }
            await refreshResources(force: true)
            guard connection == connectionState.connectionID else { throw CancellationError() }
            return result
        } catch {
            if connection == connectionState.connectionID {
                poolCleanupStatus[poolID] = "Cleanup could not be confirmed: \(error.localizedDescription) It may still be running. Refresh before trying again; nothing was retried."
                resources.invalidate(poolID, at: now()); await refresh()
            }
            throw error
        }
    }

    public func refreshResources(force: Bool = false) async {
        guard let client = connectionState.client, let projectID = connectionState.projectID, connectionState.isConnected else { return }
        _ = try? await resources.refresh(client: client, project: projectID, force: force, now: now())
    }

}
