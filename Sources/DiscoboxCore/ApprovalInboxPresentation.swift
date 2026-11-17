import Foundation
import Observation

/// Window-owned approval inbox presentation. Rows and buttons ask to show one
/// computer's inbox (optionally one box's requests); a single sheet presents
/// it with that computer's session, whichever computer is active later.
@MainActor @Observable public final class ApprovalInboxPresentation {
    public struct Request: Identifiable {
        public let id = UUID()
        public let host: ConnectionSession
        public let boxID: String?
        public let connection: UUID
    }

    public var request: Request?

    public init() {}

    /// Ignored while an inbox is already open or the computer is disconnected.
    public func present(on host: ConnectionSession, box: String? = nil) {
        guard request == nil, host.connectionState.isConnected else { return }
        request = Request(host: host, boxID: box, connection: host.connectionState.connectionID)
    }
}
