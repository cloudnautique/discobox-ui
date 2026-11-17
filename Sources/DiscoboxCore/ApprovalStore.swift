import Foundation
import Observation

@MainActor @Observable
public final class ApprovalStore {
    public private(set) var approvals: [ApprovalItem] = []
    public private(set) var approvalError: String?
    @ObservationIgnored private var approvalRequest = LatestRequest()
    func reset() { approvalRequest.invalidate(); approvals = []; approvalError = nil }
    let connectionState: ConnectionStore
    init(connection: ConnectionStore) { self.connectionState = connection }
    public func refreshApprovals() async {
        guard let client = connectionState.client, let projectID = connectionState.projectID else { return }
        let connection = connectionState.connectionID, request = approvalRequest.begin()
        do {
            let result = try await client.decode(.init(.approvals, projectID: projectID), as: ApprovalInbox.self)
            guard connectionState.connectionID == connection, approvalRequest.owns(request) else { return }
            let pending = result.approvalRequests.filter { $0.request["status"].string == "pending" }
            if approvals != pending { approvals = pending }
            approvalError = nil
        } catch {
            guard connectionState.connectionID == connection, approvalRequest.owns(request) else { return }
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

    /// Validates the request is still pending, then answers it once. After
    /// validation `proceed` can still withdraw (a closed window); nothing is
    /// sent and nil is returned. Views choose a decision; Core builds the payload.
    @discardableResult
    public func answer(_ item: ApprovalItem, _ answer: ApprovalAnswer, connection: UUID, proceed: () -> Bool = { true },
                       onAccepted: (JSONValue) -> Void = { _ in }) async throws -> JSONValue? {
        let payload = try answer.payload()
        try await validateApproval(item, connection: connection)
        guard proceed() else { return nil }
        return try await answerWithReceipt(item, action: answer.action, payload: payload, onAccepted: onAccepted)
    }

    /// Publish the acknowledgment and remove this request before an unrelated
    /// inbox refresh can stall. A committed response is never submitted twice.
    @discardableResult func answerWithReceipt(_ item: ApprovalItem, action: String, payload: JSONValue, onAccepted: (JSONValue) -> Void = { _ in }) async throws -> JSONValue {
        let connection = connectionState.connectionID
        let result = try await ScopedAPI(connection: connectionState).json(.answer, box: item.boxID, request: item.id, kind: item.kind, action: action, payload: payload)
        guard connection == connectionState.connectionID else { throw CancellationError() }
        approvalRequest.invalidate()
        approvals.removeAll { $0.id == item.id }
        onAccepted(result)
        await refreshApprovals()
        return result
    }

}
