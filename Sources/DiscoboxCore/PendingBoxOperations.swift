import Foundation
import Observation

@MainActor @Observable public final class PendingBoxOperations {
    public internal(set) var pendingBoxActions: Set<String> = []
    public internal(set) var clearingPools: Set<String> = []
    func reset() { pendingBoxActions = []; clearingPools = [] }
}
