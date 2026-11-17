import Foundation
import Observation

@MainActor @Observable
public final class HarnessCatalogStore {
    public private(set) var cachedHarnesses: [Harness] = []
    public private(set) var defaultHarnessID: String?
    @ObservationIgnored private var harnessesReadAt: Date?
    @ObservationIgnored private var harnessLoad: Task<[Harness], Error>?
    @ObservationIgnored let now: () -> Date
    func acceptProject(_ project: Project) { defaultHarnessID = project.defaultHarnessConfigId }
    func reset() { harnessLoad?.cancel(); harnessLoad = nil; harnessesReadAt = nil; cachedHarnesses = []; defaultHarnessID = nil }
    let connectionState: ConnectionStore
    init(connection: ConnectionStore, now: @escaping () -> Date) { self.connectionState = connection; self.now = now }
    public func harnesses(force: Bool = false) async throws -> [Harness] {
        guard let client = connectionState.client, let projectID = connectionState.projectID else { throw DiscoboxError("Connect to a server first.") }
        if !force, let readAt = harnessesReadAt, now().timeIntervalSince(readAt) < 60 { return cachedHarnesses }
        let connection = connectionState.connectionID
        if let harnessLoad {
            let result = try await harnessLoad.value
            guard connection == connectionState.connectionID else { throw CancellationError() }
            if cachedHarnesses != result { cachedHarnesses = result }
            harnessesReadAt = now()
            return result
        }
        let load = Task.detached(priority: .utility) {
            try await client.decode(.init(.harnesses, projectID: projectID), as: HarnessList.self).harnessConfigs ?? []
        }
        harnessLoad = load
        defer { if connection == connectionState.connectionID { harnessLoad = nil } }
        let result = try await load.value
        guard connection == connectionState.connectionID else { throw CancellationError() }
        if cachedHarnesses != result { cachedHarnesses = result }
        harnessesReadAt = now()
        return result
    }

    public func refreshDefaultHarness() async throws {
        guard connectionState.isConnected, let client = connectionState.client, let projectID = connectionState.projectID else { throw DiscoboxError("Connect to a server first.") }
        let connection = connectionState.connectionID
        let project = try await client.decode(.init(.defaultProject), as: Project.self)
        guard connection == connectionState.connectionID, !Task.isCancelled else { throw CancellationError() }
        guard project.id == projectID else { throw DiscoboxError("The default project changed. Reconnect before creating a box.") }
        defaultHarnessID = project.defaultHarnessConfigId
    }

    public func setDefaultHarness(_ harnessID: String, connection: UUID) async throws {
        guard connectionState.isConnected, connection == connectionState.connectionID, let client = connectionState.client, let projectID = connectionState.projectID,
              cachedHarnesses.contains(where: { $0.id == harnessID && $0.configured }) else {
            throw DiscoboxError("Choose an available harness on the connected computer.")
        }
        let project = try await client.decode(.init(.setDefaultHarness, projectID: projectID, harnessID: harnessID), as: Project.self)
        guard connection == connectionState.connectionID else { throw CancellationError() }
        guard project.id == projectID, project.defaultHarnessConfigId == harnessID else {
            throw DiscoboxError("The server did not confirm the default harness. Refresh before retrying.")
        }
        defaultHarnessID = project.defaultHarnessConfigId
    }

}
