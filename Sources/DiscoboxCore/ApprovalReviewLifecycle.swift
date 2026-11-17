import Foundation
import Observation

/// The lifecycle shared by every approval review form. Each format keeps its
/// own draft model; this owns only the request/connection scope, read identity
/// and the single decision (or inline credential) operation.
///
/// loading → review → validating → transmitting → recorded | uncertain.
/// Closing withdraws reads and any operation not yet sent. Once transmission
/// has begun the operation completes on its own and is never replayed; an
/// unconfirmed outcome is published to the request's computer if the form has
/// closed, because the server may already have committed it.
@MainActor @Observable public final class ApprovalReviewLifecycle {
    public enum Phase: Sendable, Equatable {
        /// Reading metadata or a preview. Deny remains available.
        case loading
        case review
        /// Checking the request is still pending. Nothing has been sent.
        case validating
        /// Sent. The outcome belongs to the server from here on.
        case transmitting
        case recorded
        /// The last write could not be confirmed and may have been committed.
        /// Decisions stay disabled until a fresh read.
        case uncertain
    }

    public let item: ApprovalItem
    /// The connection generation the request was reviewed on.
    public let connection: UUID
    public private(set) var phase: Phase
    public private(set) var receipt: JSONValue?
    public private(set) var receiptAction = ""
    public internal(set) var error: String?
    public private(set) var status = ""
    public private(set) var closed = false

    @ObservationIgnored let store: ApprovalStore
    @ObservationIgnored let credentials: CredentialService
    @ObservationIgnored private let report: @MainActor (String) -> Void
    @ObservationIgnored private var read = UUID()
    @ObservationIgnored private var recovering = false
    /// The in-flight operation, retained independently of any view.
    @ObservationIgnored public private(set) var operation: Task<Void, Never>?

    init(item: ApprovalItem, session: ConnectionSession, phase: Phase) {
        let connection = session.connectionState.connectionID
        self.item = item; self.connection = connection; self.phase = phase
        store = session.approvalStore; credentials = session.credentials
        // The request's owner is its computer's session, not the closed form.
        report = { [weak session] message in
            guard let session, session.connectionState.connectionID == connection else { return }
            session.selection.commandError = message
        }
    }

    public var isBusy: Bool { phase == .validating || phase == .transmitting }
    /// Answered elsewhere, withdrawn, replaced, or its computer reconnected.
    public var isResolved: Bool {
        phase != .recorded && (store.connectionState.connectionID != connection || !store.approvals.contains(item))
    }
    /// A decision can start from review, or from loading for Deny.
    public var canDecide: Bool { !closed && !isResolved && (phase == .review || phase == .loading) }

    // MARK: Reads

    /// Starts a read that a later read, a submission or close supersedes.
    func beginRead() -> UUID? {
        guard !closed, !isResolved, !isBusy, phase != .recorded else { return nil }
        if phase == .uncertain { recovering = true }
        read = UUID(); phase = .loading; error = nil
        return read
    }
    func owns(_ token: UUID) -> Bool { !closed && read == token && store.connectionState.connectionID == connection && !Task.isCancelled }
    func finishRead(_ token: UUID, failure: (any Error)? = nil) {
        guard owns(token) else { return }
        if let failure {
            error = failure.localizedDescription
            phase = recovering ? .uncertain : .review
        } else {
            recovering = false; phase = .review
        }
    }

    /// After an unconfirmed write, a fresh server read decides whether review
    /// may resume. Returns the read to finish once format metadata is reloaded.
    func confirmPending() async -> UUID? {
        guard phase == .uncertain, let token = beginRead() else { return nil }
        do {
            try await store.validateApproval(item, connection: connection)
            return owns(token) ? token : nil
        } catch {
            await store.refreshApprovals()
            finishRead(token, failure: error)
            return nil
        }
    }

    // MARK: Operations

    /// Freezes `answer` (a value) and answers the request at most once.
    @discardableResult func submit(_ answer: ApprovalAnswer, finished: @escaping @MainActor () -> Void = {}) -> Task<Void, Never>? {
        guard canDecide else { return nil }
        do { _ = try answer.payload() } catch { self.error = error.localizedDescription; return nil }
        read = UUID()
        phase = .validating; error = nil; status = "Checking the request on the requesting computer…"
        let task = Task { [self] in
            await transmit(answer)
            operation = nil
            finished()
        }
        operation = task
        return task
    }

    private func transmit(_ answer: ApprovalAnswer) async {
        do {
            let result = try await store.answer(item, answer, connection: connection, proceed: {
                guard !closed, phase == .validating else { return false }
                phase = .transmitting; status = "Waiting for the requesting computer to record your decision…"
                return true
            }, onAccepted: { result in
                receipt = result; receiptAction = answer.action; phase = .recorded
            })
            if result == nil { status = "" }
        } catch {
            if phase == .transmitting { await uncertain("Discobox could not confirm this decision. It may have been recorded; check the request before deciding again. " + error.localizedDescription) }
            else if !closed { phase = .review; self.error = error.localizedDescription }
        }
    }

    /// Validates, checks the form is still open, then stores one credential.
    /// Returns its ID; nil when withdrawn or failed. Never answers the request.
    func storeCredential(_ body: JSONValue) async -> String? {
        guard canDecide, phase == .review else { return nil }
        read = UUID()
        phase = .validating; error = nil; status = "Checking the request…"
        do {
            try await store.validateApproval(item, connection: connection)
            guard !closed else { return nil }
            phase = .transmitting; status = "Storing the credential on the requesting computer…"
            let made = try await credentials.create(payload: body)
            guard !made["id"].string.isEmpty else { throw DiscoboxError("The server did not return the new credential.") }
            if !closed { phase = .review }
            return closed ? nil : made["id"].string
        } catch {
            if phase == .transmitting { await uncertain("Credential may have been stored. Check Settings → Credentials before retrying. " + error.localizedDescription) }
            else if !closed { phase = .review; self.error = error.localizedDescription }
            return nil
        }
    }

    private func uncertain(_ message: String) async {
        phase = .uncertain
        if closed { report(message) } else { error = message }
        // A read only: a committed decision then shows as no longer pending.
        await store.refreshApprovals()
    }

    /// Withdraws pending reads and any validation that has not sent anything.
    /// A transmitted operation continues to its receipt or uncertain failure.
    func close() {
        guard !closed else { return }
        closed = true
        read = UUID()
    }
}
