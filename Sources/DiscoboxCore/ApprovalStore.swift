import Foundation
import Observation

@MainActor @Observable
public final class ApprovalStore {
    public private(set) var approvals: [ApprovalItem] = []
    public private(set) var approvalError: String?
    @ObservationIgnored private var approvalRequest = UUID()
    func reset() { approvalRequest = UUID(); approvals = []; approvalError = nil }
    let connectionState: ConnectionStore
    init(connection: ConnectionStore) { self.connectionState = connection }
    public func refreshApprovals() async {
        guard let client = connectionState.client, let projectID = connectionState.projectID else { return }
        let connection = connectionState.connectionID, request = UUID()
        approvalRequest = request
        do {
            let result = try await client.decode(.init(.approvals, projectID: projectID), as: ApprovalInbox.self)
            guard connectionState.connectionID == connection, approvalRequest == request, !Task.isCancelled else { return }
            let pending = result.approvalRequests.filter { $0.request["status"].string == "pending" }
            if approvals != pending { approvals = pending }
            approvalError = nil
        } catch {
            guard connectionState.connectionID == connection, approvalRequest == request, !Task.isCancelled else { return }
            approvalError = error.localizedDescription
        }
    }

    public func approvalSecrets() async throws -> [JSONValue] {
        let body = try await ScopedAPI(connection: connectionState).json(.secrets)
        return body["secrets"].array
    }

    public func context(item: ApprovalItem, payload: JSONValue?) async throws -> JSONValue {
        try await ScopedAPI(connection: connectionState).json(.approvalContext, box: item.boxID, request: item.id, payload: payload)
    }

    public func validateApproval(_ item: ApprovalItem, connection: UUID) async throws {
        guard connectionState.isConnected, connectionState.connectionID == connection, let client = connectionState.client, let projectID = connectionState.projectID else {
            throw DiscoboxError("The computer reconnected or disconnected. Open the current request in Discobox.")
        }
        let result = try await client.decode(.init(.approvals, projectID: projectID), as: ApprovalInbox.self)
        guard connectionState.connectionID == connection, connectionState.isConnected, item.request["status"].string == "pending",
              result.approvalRequests.contains(item) else {
            throw DiscoboxError("The request changed or was answered elsewhere. Check the approval inbox.")
        }
    }

    public func answer(_ item: ApprovalItem, action: String, payload: JSONValue, onAccepted: () -> Void = {}) async throws {
        _ = try await answerWithReceipt(item, action: action, payload: payload, onAccepted: { _ in onAccepted() })
    }

    @discardableResult public func answerWithReceipt(_ item: ApprovalItem, action: String, payload: JSONValue, onAccepted: (JSONValue) -> Void = { _ in }) async throws -> JSONValue {
        let connection = connectionState.connectionID
        let result = try await ScopedAPI(connection: connectionState).json(.answer, box: item.boxID, request: item.id, kind: item.kind, action: action, payload: payload)
        guard connection == connectionState.connectionID else { throw CancellationError() }
        approvalRequest = UUID()
        approvals.removeAll { $0.id == item.id }
        onAccepted(result)
        await refreshApprovals()
        return result
    }

}
