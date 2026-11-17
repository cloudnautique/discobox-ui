import Foundation
import Observation

public struct SessionScope: Equatable, Sendable {
    public let generation: UUID
    public let project: String
}

/// Captures an exact client and project. Selection changes cannot retarget it.
@MainActor struct SessionAccess {
    let client: any DiscoboxClient
    let scope: SessionScope
    let owner: ConnectionStore
    var isCurrent: Bool { owner.connectionID == scope.generation && owner.projectID == scope.project }
    func perform(_ request: BridgeRequest) async throws -> Data {
        guard isCurrent else { throw CancellationError() }
        let result = try await client.perform(request)
        guard isCurrent, !Task.isCancelled else { throw CancellationError() }
        return result
    }
}
