import Foundation
import Observation

@MainActor @Observable public final class PendingBoxOperations {
    public internal(set) var pendingBoxActions: Set<String> = [] {
        didSet { let began = pendingBoxActions.subtracting(oldValue); if !began.isEmpty { lifecycle(.boxActionsBegan(began)) } }
    }
    public internal(set) var clearingPools: Set<String> = []
    /// Lifecycle transitions, wired by ConnectionSession (see ConnectionLifecycleEvent).
    @ObservationIgnored var lifecycle: @MainActor (ConnectionLifecycleEvent) -> Void = { _ in }
    func reset() { pendingBoxActions = []; clearingPools = [] }
}
