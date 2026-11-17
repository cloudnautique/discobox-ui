import Foundation
import Observation

/// Waits for main-actor observable state instead of polling it: `condition`
/// is re-evaluated only when a property it read changes.
public enum ObservedCondition {
    /// Returns true as soon as `condition` holds, or false after `timeout` or
    /// when the calling task is cancelled.
    @MainActor public static func wait(timeout: Duration, until condition: @escaping @MainActor () -> Bool) async -> Bool {
        if condition() { return true }
        let waiter = Waiter(condition)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.begin(continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(false) }
        }
    }

    @MainActor private final class Waiter {
        private let condition: @MainActor () -> Bool
        private var continuation: CheckedContinuation<Bool, Never>?
        private var deadline: Task<Void, Never>?
        private var done = false
        init(_ condition: @escaping @MainActor () -> Bool) { self.condition = condition }

        func begin(_ continuation: CheckedContinuation<Bool, Never>, timeout: Duration) {
            // Cancellation may have arrived before the continuation existed.
            guard !done, !Task.isCancelled else { continuation.resume(returning: false); done = true; return }
            self.continuation = continuation
            deadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(false)
            }
            check()
        }
        private func check() {
            guard !done else { return }
            let satisfied = withObservationTracking { condition() } onChange: { [weak self] in
                // Fires before the change is stored; re-read after it lands.
                Task { @MainActor [weak self] in self?.check() }
            }
            if satisfied { finish(true) }
        }
        func finish(_ value: Bool) {
            guard !done else { return }
            done = true
            deadline?.cancel(); deadline = nil
            continuation?.resume(returning: value); continuation = nil
        }
    }
}
