import Foundation

/// Only the most recently started request of one kind may publish its result.
/// Each store owns its own: the lifetimes these tokens protect differ and must
/// not collapse into one global token (see the workspace refactor plan).
struct LatestRequest {
    private var current = UUID()
    /// Starts a request, superseding any earlier one, and returns its token.
    mutating func begin() -> UUID { current = UUID(); return current }
    /// True only for the latest request, and only while its task is not cancelled.
    func owns(_ token: UUID) -> Bool { token == current && !Task.isCancelled }
    /// Discards every in-flight request.
    mutating func invalidate() { current = UUID() }
}
