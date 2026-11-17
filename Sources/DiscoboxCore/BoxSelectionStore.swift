import Foundation
import Observation

@MainActor @Observable
public final class BoxSelectionStore {
    public private(set) var execs: [Exec] = []
    public private(set) var terminalInventory: TerminalInventory?
    public private(set) var services: [Service] = []
    public private(set) var sandboxID: String?
    public private(set) var execID: String?
    public private(set) var inventoryObservedAt: String?
    public private(set) var servicesObservedAt: String?
    public private(set) var detailError: String?
    public private(set) var isOpeningShell = false
    public private(set) var isOpeningSession = false
    public var commandError: String?
    @ObservationIgnored var selectionRevision = UUID()
    @ObservationIgnored private var detailsRequest = UUID()
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
        let load = Task { await refreshDetails() }
        selectionLoad = load
        await load.value
    }

    public func selectExec(_ id: String?) async {
        guard execID != id else { return }
        execID = id
    }

    public func refreshDetails() async {
        guard let client = connectionState.client, let projectID = connectionState.projectID, let sandboxID else { return }
        let current = selectionRevision
        let request = UUID()
        detailsRequest = request
        do {
            async let execResult = client.decode(.init(.execs, projectID: projectID, sandboxID: sandboxID), as: ExecsResponse.self)
            async let serviceResult = client.decode(.init(.services, projectID: projectID, sandboxID: sandboxID), as: ServicesResponse.self)
            // Publish terminal inventory as soon as it arrives. Service discovery
            // can be slow and must not delay mounting an interactive terminal.
            let terminals = try await execResult
            guard current == selectionRevision, request == detailsRequest, !Task.isCancelled else { return }
            let updatedExecs = terminals.execs.filter(\.tty).sorted {
                if ($0.primary == true) != ($1.primary == true) { return $0.primary == true }
                return $0.id < $1.id
            }
            if terminals.observedAt == nil, selectedBox?.isRunning == true {
                let inventory = TerminalInventory(project: projectID, box: sandboxID,
                    execIDs: Set(updatedExecs.filter(\.acceptsInput).map(\.id)))
                if terminalInventory != inventory { terminalInventory = inventory }
            }
            if execs != updatedExecs { execs = updatedExecs }
            inventoryLoadedAt = now()
            if inventoryObservedAt != terminals.observedAt { inventoryObservedAt = terminals.observedAt }
            detailError = nil
            if !execs.contains(where: { $0.id == execID }) {
                await selectExec(execs.first(where: { $0.primary == true })?.id ?? execs.first?.id)
            }
            let serviceList = try await serviceResult
            guard current == selectionRevision, request == detailsRequest, !Task.isCancelled else { return }
            if services != serviceList.services { services = serviceList.services }
            if servicesObservedAt != serviceList.observedAt { servicesObservedAt = serviceList.observedAt }
        } catch {
            guard current == selectionRevision, request == detailsRequest, !Task.isCancelled else { return }
            detailError = error.localizedDescription
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
        await refreshDetails()
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
        await refreshDetails()
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
            await refreshDetails()
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
