import Foundation
import Observation

/// Explicit consent for API authority, adoption and token replacement. These
/// are not credential grants and never inherit credential-approval fields.
@MainActor @Observable public final class ConsentApprovalReview {
    public let lifecycle: ApprovalReviewLifecycle
    public var item: ApprovalItem { lifecycle.item }
    /// A manually entered replacement token (refresh only).
    public var value = ""
    /// Set once the whole summary has been visible.
    public var reviewed = false

    public init(_ item: ApprovalItem, in session: ConnectionSession) {
        lifecycle = ApprovalReviewLifecycle(item: item, session: session, phase: .review)
    }

    public var isRefresh: Bool { item.kind == "refresh" }
    public var approveTitle: String { isRefresh ? "Update credential" : item.kind == "apiAccess" ? "Enable API access" : "Allow leadership" }
    public var approved: Bool { lifecycle.receiptAction != "deny" }
    public var canApprove: Bool { lifecycle.phase == .review && !lifecycle.isResolved && item.supported && reviewed && (!isRefresh || !value.isEmpty) }

    @discardableResult public func submit(approve: Bool) -> Task<Void, Never>? {
        guard item.supported, !approve || canApprove else { return nil }
        let answer: ApprovalAnswer = !approve ? .deny : isRefresh ? .refresh(token: value) : .approve
        return lifecycle.submit(answer) { [weak self] in self?.value = "" }
    }

    /// After an unconfirmed decision: read the inbox again before deciding.
    public func recheck() async {
        if let token = await lifecycle.confirmPending() { lifecycle.finishRead(token) }
    }

    public func close() { lifecycle.close(); value = "" }
}
