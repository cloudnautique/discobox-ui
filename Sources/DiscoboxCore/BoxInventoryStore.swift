import Foundation
import Observation

@MainActor @Observable
public final class BoxInventoryStore {
    public private(set) var sandboxes: [Sandbox] = []
    public private(set) var boxesObservedAt: Date?
    public private(set) var lastRefresh: Date?
    @ObservationIgnored private var listRequest = UUID()
    @ObservationIgnored private var confirmedPurges: Set<String> = []
    public init() {}
    func refresh(using connection: ConnectionStore, now: () -> Date) async throws -> UUID? {
        let access = try connection.capture(), request = UUID()
        listRequest = request
        do {
            try await connection.prepareTransport()
            guard access.isCurrent, request == listRequest, !Task.isCancelled else { return nil }
            let data = try await access.perform(.init(.sandboxes, projectID: access.scope.project))
            let result = try JSONDecoder().decode(SandboxesResponse.self, from: data)
            guard request == listRequest else { return nil }
            let updated = (result.sandboxes ?? []).filter { !$0.isDeleted && !confirmedPurges.contains($0.id) }
            boxesObservedAt = now()
            if sandboxes != updated { sandboxes = updated }
            return request
        } catch {
            guard access.isCurrent, request == listRequest, !Task.isCancelled else { return nil }
            throw error
        }
    }
    func complete(_ request: UUID, at date: Date) {
        if request == listRequest { lastRefresh = date }
    }
    func acknowledgePurge(_ id: String) {
        confirmedPurges.insert(id)
        sandboxes.removeAll { $0.id == id }
    }
    func includeCreated(_ box: Sandbox) {
        if !sandboxes.contains(where: { $0.id == box.id }) { sandboxes.append(box) }
    }
    func reset() { sandboxes = []; boxesObservedAt = nil; lastRefresh = nil; listRequest = UUID(); confirmedPurges = [] }
}
