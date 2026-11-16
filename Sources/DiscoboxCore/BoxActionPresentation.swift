import Foundation
import Observation

/// Window-owned confirmation state. A row can disappear or change computers
/// without replacing the destination of an already-open confirmation.
@MainActor @Observable public final class BoxActionPresentation {
    public struct Request: Identifiable {
        public let id = UUID()
        public let host: ConnectionSession
        public let box: Sandbox
        public let action: BoxAction
        public let connection: UUID
    }

    public var request: Request?

    public init() {}

    public func present(_ action: BoxAction, box: Sandbox, on host: ConnectionSession, connection: UUID) {
        let workspace = host.workspace
        guard request == nil, workspace.isConnected, workspace.connectionID == connection,
              let current = workspace.sandboxes.first(where: { $0.id == box.id }),
              action.isAvailable(for: current),
              !workspace.pendingBoxActions.contains(box.id),
              !workspace.clearingPools.contains(current.poolId ?? "") else { return }
        request = Request(host: host, box: current, action: action, connection: connection)
    }
}
