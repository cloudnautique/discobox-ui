import Foundation

/// Runs blocking work — child-process pipe reads and `waitUntilExit` — on a
/// thread of its own. Swift concurrency's cooperative pool has about one
/// thread per core; a request blocked there for the lifetime of a helper
/// process (or a long file transfer) stalls every other async task in the app.
/// Each companion request already owns one process, so one thread per
/// in-flight request is proportionate. Cancellation stays with the caller,
/// which signals the work (for example by terminating its process) so that
/// `work` returns.
public enum BlockingThread {
    public static func run<T: Sendable>(name: String, priority: TaskPriority? = nil,
                                 _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let qos = qualityOfService(for: priority ?? Task.currentPriority)
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try work() }) }
            thread.name = name
            thread.qualityOfService = qos
            thread.start()
        }
    }

    static func qualityOfService(for priority: TaskPriority) -> QualityOfService {
        switch priority.rawValue {
        case TaskPriority.userInitiated.rawValue...: .userInitiated
        case TaskPriority.medium.rawValue...: .default
        case TaskPriority.utility.rawValue...: .utility
        default: .background
        }
    }
}
