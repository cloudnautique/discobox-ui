import Foundation
import Observation

@MainActor @Observable
public final class BoxSelectionStore {
    public private(set) var execs: [Exec] = []
    public private(set) var terminalObservation: UUID?
    public private(set) var terminalInventory: TerminalInventory?
    public private(set) var services: [Service] = []
    public private(set) var sandboxID: String?
    public private(set) var execID: String?
    public private(set) var inventoryObservedAt: String?
    public private(set) var servicesObservedAt: String?
    public private(set) var serviceError: String?
    public private(set) var detailError: String?
    public private(set) var isOpeningShell = false
    public private(set) var isOpeningSession = false
    public var commandError: String?
    @ObservationIgnored var selectionRevision = UUID()
    @ObservationIgnored var guestBudget = GuestReadBudget()
    @ObservationIgnored private var execReads = DetailRead()
    @ObservationIgnored private var serviceReads = DetailRead()
    private struct DetailRead {
        var request: UUID?
        var completed: Date?
        var failures = 0
        func due(at now: Date, interval: TimeInterval) -> Bool {
            guard request == nil else { return false }
            guard let completed else { return true }
            let backoff = failures == 0 ? 0 : min(300, 30 * pow(2, Double(failures - 1)))
            return now.timeIntervalSince(completed) >= max(interval, backoff)
        }
        mutating func finish(at now: Date, success: Bool) {
            completed = now
            request = nil
            failures = success ? 0 : min(failures + 1, 5)
        }
    }
    @ObservationIgnored private var serviceViews: [UUID: String] = [:]
    public func showServices(for box: String, token: UUID) {
        serviceViews[token] = box
    }
    public func hideServices(_ token: UUID) { serviceViews.removeValue(forKey: token) }
    public func refreshVisibleServices() async {
        guard let box = sandboxID, serviceViews.values.contains(box),
              serviceReads.due(at: now(), interval: 30) else { return }
        await readServices()
    }
    func reconcileDetails(cadence: PollingCadence) async {
        guard cadence.isActiveHost, cadence.presence != .hidden,
              let box = selectedBox, box.isRunning else { return }
        let focused = cadence.presence == .focused
        let needsExecs = execReads.due(at: now(), interval: focused ? 30 : 60)
        let needsServices = serviceViews.values.contains(box.id)
            && serviceReads.due(at: now(), interval: focused ? 60 : 120)
        await refreshDetails(execs: needsExecs, services: needsServices, scheduled: true)
    }
    @ObservationIgnored private var recentBoxes: [String: RecentBox] = [:]
    @ObservationIgnored private var inventoryLoadedAt: Date?
    @ObservationIgnored private var selectionLoad: Task<Void, Never>?
    public struct TerminalInventory: Equatable, Sendable {
        public let project: String
        public let box: String
        public let execIDs: Set<String>
    }
    struct RecentBox {
        let execs: [Exec]
        let selectedExec: String?
        let services: [Service]
        let servicesObservedAt: String?
        let loadedAt: Date
    }
    public var selectedBox: Sandbox? { inventory.sandboxes.first { $0.id == sandboxID } }
    public var selectedExec: Exec? { execs.first { $0.id == execID } }
    public var hasLiveTerminal: Bool {
        connectionState.isConnected && selectedBox?.isRunning == true && selectedExec?.acceptsInput == true &&
        inventoryObservedAt == nil && execID != "primary"
    }
    let connectionState: ConnectionStore
    let inventory: BoxInventoryStore
    let pending: PendingBoxOperations
    @ObservationIgnored let now: () -> Date
    init(connection: ConnectionStore, inventory: BoxInventoryStore, pending: PendingBoxOperations, now: @escaping () -> Date) {
        self.connectionState = connection; self.inventory = inventory; self.pending = pending; self.now = now
    }
    func reconcileInventory() {
        let running = Set(inventory.sandboxes.filter(\.isRunning).map(\.id))
        recentBoxes = recentBoxes.filter { running.contains($0.key) && now().timeIntervalSince($0.value.loadedAt) < 30 }
        if let sandboxID, !inventory.sandboxes.contains(where: { $0.id == sandboxID }) { clearSelection() }
    }
    private func rememberSelection() {
        guard let sandboxID, selectedBox?.isRunning == true,
              !pending.pendingBoxActions.contains(sandboxID), detailError == nil,
              inventoryObservedAt == nil, let loadedAt = inventoryLoadedAt,
              now().timeIntervalSince(loadedAt) < 30 else { return }
        recentBoxes[sandboxID] = RecentBox(execs: execs, selectedExec: execID,
            services: services, servicesObservedAt: servicesObservedAt, loadedAt: loadedAt)
        if recentBoxes.count > 12, let oldest = recentBoxes.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
            recentBoxes.removeValue(forKey: oldest)
        }
    }

    public func selectBox(_ id: String?) async {
        if let id, !inventory.sandboxes.contains(where: { $0.id == id && !$0.isDeleted }) { return }
        guard sandboxID != id else { return }
        rememberSelection()
        clearSelection()
        sandboxID = id
        // Reattach the already-retained Ghostty surface before an API round trip.
        // Only recent, live inventories qualify; backend checks still gate a new attach.
        if let id, selectedBox?.isRunning == true, !pending.pendingBoxActions.contains(id),
           let cached = recentBoxes[id], now().timeIntervalSince(cached.loadedAt) < 30 {
            execs = cached.execs
            execID = cached.execs.first(where: { $0.id == cached.selectedExec })?.id
                ?? cached.execs.first(where: { $0.primary == true })?.id ?? cached.execs.first?.id
            services = cached.services
            servicesObservedAt = cached.servicesObservedAt
            inventoryLoadedAt = cached.loadedAt
        }
        let load = Task {
            await refreshDetails(execs: true, services: id.map { serviceViews.values.contains($0) } ?? false)
        }
        selectionLoad = load
        await load.value
    }

    public func selectExec(_ id: String?) async {
        guard execID != id else { return }
        execID = id
    }

    public func refreshDetails() async {
        await refreshDetails(execs: true, services: true)
    }

    private func refreshDetails(execs: Bool, services: Bool, scheduled: Bool = false) async {
        let revision = selectionRevision
        async let first: Void = readExecsIfNeeded(execs, revision: revision, scheduled: scheduled)
        if services { await readServices(scheduled: scheduled) }
        await first
    }

    private func readExecsIfNeeded(_ needed: Bool, revision: UUID, scheduled: Bool) async {
        guard needed, revision == selectionRevision, !Task.isCancelled,
              let client = connectionState.client, let projectID = connectionState.projectID, let sandboxID else { return }
        let pool = selectedBox?.poolId ?? ""
        let budget = guestBudget
        guard !scheduled || budget.begin(pool: pool, project: projectID, at: now()) else { return }
        var outcome: Result<Void, Error>?
        defer { if scheduled { budget.finish(pool: pool, project: projectID, at: now(), result: outcome) } }
        let request = UUID()
        execReads.request = request
        do {
            let terminals = try await client.decode(.init(.execs, projectID: projectID, sandboxID: sandboxID), as: ExecsResponse.self)
            guard execReads.request == request else { return }
            execReads.request = nil
            guard !Task.isCancelled else { return }
            outcome = .success(())
            execReads.finish(at: now(), success: true)
            let updatedExecs = terminals.execs.filter(\.tty).sorted {
                if ($0.primary == true) != ($1.primary == true) { return $0.primary == true }
                return $0.id < $1.id
            }
            if terminals.observedAt == nil, selectedBox?.isRunning == true {
                let inventory = TerminalInventory(project: projectID, box: sandboxID,
                    execIDs: Set(updatedExecs.filter(\.acceptsInput).map(\.id)))
                if terminalInventory != inventory { terminalInventory = inventory }
                terminalObservation = request
            }
            if execs != updatedExecs { execs = updatedExecs }
            inventoryLoadedAt = now()
            if inventoryObservedAt != terminals.observedAt { inventoryObservedAt = terminals.observedAt }
            detailError = nil
            if !execs.contains(where: { $0.id == execID }) {
                await selectExec(execs.first(where: { $0.primary == true })?.id ?? execs.first?.id)
            }
        } catch {
            guard execReads.request == request else { return }
            execReads.request = nil
            guard !Task.isCancelled else { return }
            outcome = .failure(error)
            execReads.finish(at: now(), success: false)
            detailError = error.localizedDescription
        }
    }

    private func readServices(scheduled: Bool = false) async {
        guard !Task.isCancelled, let client = connectionState.client,
              let projectID = connectionState.projectID, let sandboxID else { return }
        let pool = selectedBox?.poolId ?? ""
        let budget = guestBudget
        guard !scheduled || budget.begin(pool: pool, project: projectID, at: now()) else { return }
        var outcome: Result<Void, Error>?
        defer { if scheduled { budget.finish(pool: pool, project: projectID, at: now(), result: outcome) } }
        let request = UUID()
        serviceReads.request = request
        do {
            let result = try await client.decode(.init(.services, projectID: projectID, sandboxID: sandboxID), as: ServicesResponse.self)
            guard serviceReads.request == request else { return }
            serviceReads.request = nil
            guard !Task.isCancelled else { return }
            outcome = .success(())
            serviceReads.finish(at: now(), success: true)
            if services != result.services { services = result.services }
            if servicesObservedAt != result.observedAt { servicesObservedAt = result.observedAt }
            serviceError = nil
        } catch {
            guard serviceReads.request == request else { return }
            serviceReads.request = nil
            guard !Task.isCancelled else { return }
            outcome = .failure(error)
            serviceReads.finish(at: now(), success: false)
            serviceError = error.localizedDescription
        }
    }

    public func canAttachTerminal(_ terminal: Exec) -> Bool {
        connectionState.isConnected && !pending.pendingBoxActions.contains(sandboxID ?? "") && selectedBox?.isRunning == true &&
        terminal.acceptsInput && execs.contains(where: { $0.id == terminal.id && $0.acceptsInput }) && inventoryObservedAt == nil
    }

    public func terminalSnapshot(exec: String) async throws -> TerminalScreen {
        guard let client = connectionState.client, let projectID = connectionState.projectID, let sandboxID,
              execs.contains(where: { $0.id == exec }) else { throw DiscoboxError("Terminal is no longer available.") }
        let generation = connectionState.connectionID, selection = selectionRevision
        let result = try await client.decode(.init(.screen, projectID: projectID, sandboxID: sandboxID, execID: exec), as: TerminalScreen.self)
        guard generation == connectionState.connectionID, selection == selectionRevision, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    public func fileAccess() throws -> FileAccess {
        let access = try connectionState.capture()
        guard let sandboxID, selectedBox?.isRunning == true else { throw DiscoboxError("Select a running box.") }
        return FileAccess(client: access.client, project: access.scope.project, box: sandboxID)
    }

    public func openSession(tool: String? = nil, base: String = "", head: String = "") async throws {
        guard !isOpeningSession else { throw DiscoboxError("A session is already being opened.") }
        let selection = selectionRevision
        isOpeningSession = true
        defer { if selection == selectionRevision { isOpeningSession = false } }
        guard let client = connectionState.client, let projectID = connectionState.projectID, let sandboxID, selectedBox?.isRunning == true else { throw DiscoboxError("Select a running box.") }
        let payload: JSONValue? = base.isEmpty ? nil : .object(["base": .string(base), "head": .string(head)])
        let created = try await client.decode(.init(tool == nil ? .newAgent : .openTool, projectID: projectID, sandboxID: sandboxID, toolID: tool, action: base.isEmpty ? nil : "review", payload: payload), as: Exec.self)
        guard selection == selectionRevision else { return }
        await refreshDetails(execs: true, services: false)
        guard selection == selectionRevision else { return }
        if !execs.contains(where: { $0.id == created.id }) { execs.append(created) }
        await selectExec(created.id)
    }

    public func closeShell(_ id: String) async throws {
        guard let client = connectionState.client, let projectID = connectionState.projectID, let sandboxID,
              execs.contains(where: { $0.id == id && $0.primary != true && $0.tty }) else { throw DiscoboxError("Select a shell terminal.") }
        let current = selectionRevision
        let connection = connectionState.connectionID
        _ = try await client.perform(.init(execs.first(where: { $0.id == id })?.isShell == true ? .closeShell : .closeTerminal, projectID: projectID, sandboxID: sandboxID, execID: id))
        if connection == connectionState.connectionID { recentBoxes.removeValue(forKey: sandboxID) }
        guard current == selectionRevision else { return }
        execs.removeAll { $0.id == id }
        await selectExec(execs.first?.id)
        await refreshDetails(execs: true, services: false)
    }

    public func openShell() async {
        guard !isOpeningShell else { return }
        guard selectedBox?.isRunning == true, inventoryObservedAt == nil, connectionState.connectionError == nil, detailError == nil,
              let client = connectionState.client, let projectID = connectionState.projectID, let sandboxID else {
            commandError = "Choose a running box to open a shell."
            return
        }
        let current = selectionRevision
        isOpeningShell = true
        commandError = nil
        defer { if current == selectionRevision { isOpeningShell = false } }
        do {
            let created = try await client.decode(.init(.newShell, projectID: projectID, sandboxID: sandboxID), as: Exec.self)
            guard current == selectionRevision else { return }
            await refreshDetails(execs: true, services: false)
            guard current == selectionRevision else { return }
            if !execs.contains(where: { $0.id == created.id }) { execs.append(created) }
            await selectExec(created.id)
        } catch {
            guard current == selectionRevision else { return }
            commandError = error.localizedDescription
        }
    }

    func invalidateCachedBox(_ id: String) { recentBoxes.removeValue(forKey: id) }
    func reset() { clearSelection(); recentBoxes.removeAll(); terminalInventory = nil }

    func clearSelection() {
        selectionLoad?.cancel()
        selectionLoad = nil
        execReads = DetailRead()
        serviceReads = DetailRead()
        serviceError = nil
        inventoryLoadedAt = nil
        selectionRevision = UUID()
        isOpeningSession = false; isOpeningShell = false
        commandError = nil
        sandboxID = nil
        execID = nil
        execs = []
        services = []
        detailError = nil
        inventoryObservedAt = nil
        servicesObservedAt = nil
    }

}
