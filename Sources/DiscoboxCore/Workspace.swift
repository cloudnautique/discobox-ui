import Foundation
import Observation

@MainActor @Observable
public final class Workspace {
    public private(set) var connectionID = UUID()
    public private(set) var usage = HarnessUsage()
    public private(set) var cachedHarnesses: [Harness] = []
    @ObservationIgnored private var harnessesReadAt: Date?
    @ObservationIgnored private var harnessLoad: Task<[Harness], Error>?
    public var streamsLiveTerminals = false
    public private(set) var sandboxes: [Sandbox] = []
    public private(set) var execs: [Exec] = []
    /// A successful live inventory, separate from the empty/loading selection
    /// transition so switching boxes never evicts their cached terminals.
    public struct TerminalInventory: Equatable, Sendable {
        public let project: String
        public let box: String
        public let execIDs: Set<String>
    }
    public private(set) var terminalInventory: TerminalInventory?
    public private(set) var services: [Service] = []
    public private(set) var screen: TerminalScreen?
    public private(set) var projectID: String?
    public private(set) var sandboxID: String?
    public private(set) var execID: String?
    public private(set) var isConnected = false
    public private(set) var isConnecting = false
    public private(set) var isDemo = false
    public private(set) var isSending = false
    public private(set) var endpointLabel = ""
    public private(set) var transportEndpoint = ""
    public private(set) var lastRefresh: Date?
    public private(set) var inventoryObservedAt: String?
    public private(set) var servicesObservedAt: String?
    public private(set) var connectionError: String?
    public private(set) var detailError: String?
    public private(set) var screenError: String?
    public private(set) var isOpeningShell = false
    public private(set) var isOpeningSession = false
    public private(set) var approvals: [ApprovalItem] = []
    public private(set) var approvalError: String?
    @ObservationIgnored private var approvalRequest = UUID()
    public private(set) var pendingBoxActions: Set<String> = []
    public var commandError: String?
    public var inputError: String?
    public var inputEnabled = false
    public var draft = ""
    public var searchText = ""
    public var filter: BoxFilter = .all

    @ObservationIgnored private var client: (any DiscoboxClient)?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var selectionRevision = UUID()
    @ObservationIgnored private var terminalRevision = UUID()
    @ObservationIgnored private var listRequest = UUID()
    @ObservationIgnored private var detailsRequest = UUID()
    @ObservationIgnored private var screenRequest = UUID()

    public enum BoxFilter: String, CaseIterable, Identifiable {
        case all = "All boxes", running = "Running", attention = "Needs attention", archived = "Archived"
        public var id: Self { self }
    }

    private struct RecentBox {
        let execs: [Exec]
        let selectedExec: String?
        let services: [Service]
        let servicesObservedAt: String?
        let loadedAt: Date
    }
    @ObservationIgnored private var recentBoxes: [String: RecentBox] = [:]
    @ObservationIgnored private var inventoryLoadedAt: Date?
    @ObservationIgnored private var selectionLoad: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date

    public init() { now = Date.init }
    init(now: @escaping () -> Date) { self.now = now }

    private func rememberSelection() {
        guard let sandboxID, selectedBox?.isRunning == true,
              !pendingBoxActions.contains(sandboxID), detailError == nil,
              inventoryObservedAt == nil, let loadedAt = inventoryLoadedAt,
              now().timeIntervalSince(loadedAt) < 30 else { return }
        recentBoxes[sandboxID] = RecentBox(execs: execs, selectedExec: execID,
            services: services, servicesObservedAt: servicesObservedAt, loadedAt: loadedAt)
        if recentBoxes.count > 12, let oldest = recentBoxes.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
            recentBoxes.removeValue(forKey: oldest)
        }
    }

    public var selectedBox: Sandbox? { sandboxes.first { $0.id == sandboxID } }
    public var selectedExec: Exec? { execs.first { $0.id == execID } }
    public var canSendInput: Bool {
        isConnected && connectionError == nil && detailError == nil && screenError == nil &&
        selectedBox?.isRunning == true && selectedExec?.acceptsInput == true &&
        inventoryObservedAt == nil && screen?.observedAt == nil && screen?.exited == false
    }
    /// Switcher ordering is independent of the sidebar's filters/grouping.
    public var switcherBoxes: [Sandbox] {
        let waiting = Set(approvals.map(\.boxID))
        func priority(_ box: Sandbox) -> Int {
            if box.matchesAttention || waiting.contains(box.id) { return 0 }
            if box.isRunning { return 1 }
            switch box.status.lowercased() {
            case "starting", "pending", "awaiting source", "stopping": return 2
            case "stopped": return 3
            default: return 4
            }
        }
        return sandboxes.filter { !$0.isArchived }.sorted { lhs, rhs in
            let left = priority(lhs), right = priority(rhs)
            if left != right { return left < right }
            let names = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return names == .orderedSame ? lhs.id < rhs.id : names == .orderedAscending
        }
    }

    public var visibleBoxes: [Sandbox] {
        sandboxes.filter { box in
            let included: Bool
            switch filter {
            case .all: included = !box.isArchived
            case .running: included = box.isRunning
            case .attention: included = box.matchesAttention || approvals.contains { $0.boxID == box.id }
            case .archived: included = box.isArchived
            }
            return included && box.matchesSearch(searchText)
        }
    }

    public func connect(client: any DiscoboxClient, label: String, demo: Bool = false) async {
        disconnect()
        self.client = client
        endpointLabel = label
        isDemo = demo
        isConnecting = true
        let current = revision
        do {
            let transport = try await client.prepareConnection()
            guard current == revision, !Task.isCancelled else { return }
            transportEndpoint = transport ?? label
            let project = try await client.decode(.init(.defaultProject), as: Project.self)
            guard current == revision, !Task.isCancelled else { return }
            projectID = project.id
            isConnected = true
            Task { [weak self] in
                guard let self, self.revision == current else { return }
                _ = try? await self.harnesses()
            }
            await refresh()
            guard current == revision, !Task.isCancelled else { return }
            isConnecting = false
            if connectionError != nil { isConnected = false }
        } catch {
            guard current == revision else { return }
            isConnecting = false
            connectionError = error.localizedDescription
        }
    }

    public func disconnect() {
        revision = UUID()
        connectionID = UUID()
        client?.closeConnection()
        client = nil
        recentBoxes.removeAll()
        terminalInventory = nil
        transportEndpoint = ""
        usage = HarnessUsage()
        harnessLoad?.cancel(); harnessLoad = nil
        cachedHarnesses = []; harnessesReadAt = nil
        approvals = []; approvalError = nil; approvalRequest = UUID()
        sandboxes = []
        pendingBoxActions = []
        projectID = nil
        isConnected = false
        isConnecting = false
        isDemo = false
        lastRefresh = nil
        connectionError = nil
        clearSelection()
    }

    public func selectBox(_ id: String?) async {
        guard sandboxID != id else { return }
        rememberSelection()
        clearSelection()
        sandboxID = id
        // Reattach the already-retained Ghostty surface before an API round trip.
        // Only recent, live inventories qualify; backend checks still gate a new attach.
        if let id, selectedBox?.isRunning == true, !pendingBoxActions.contains(id),
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
        terminalRevision = UUID()
        execID = id
        screen = nil
        screenError = nil
        inputEnabled = false
        draft = ""
        inputError = nil
        await refreshScreen()
    }

    public func refresh() async {
        guard isConnected, let client, let projectID else { return }
        let current = revision
        let request = UUID()
        listRequest = request
        do {
            let result = try await client.decode(.init(.sandboxes, projectID: projectID), as: SandboxesResponse.self)
            guard current == revision, request == listRequest, !Task.isCancelled else { return }
            let updatedBoxes = result.sandboxes ?? []
            if sandboxes != updatedBoxes { sandboxes = updatedBoxes }
            let running = Set(updatedBoxes.filter(\.isRunning).map(\.id))
            recentBoxes = recentBoxes.filter { running.contains($0.key) && now().timeIntervalSince($0.value.loadedAt) < 30 }
            connectionError = nil
            lastRefresh = Date()
            if let sandboxID, !sandboxes.contains(where: { $0.id == sandboxID }) { clearSelection() }
            if selectedBox?.isRunning != true { inputEnabled = false }
            await refreshDetails()
        } catch {
            guard current == revision, request == listRequest, !Task.isCancelled else { return }
            connectionError = error.localizedDescription
            inputEnabled = false
        }
    }

    /// Captures the target and connection; a selection change never retargets an intent.
    public func performBoxAction(_ action: BoxAction, boxID: String, connection: UUID, name: String = "", refreshAfter: Bool = true, beforeRequest: () -> Void = {}) async throws {
        guard connection == connectionID, let client, let projectID,
              let box = sandboxes.first(where: { $0.id == boxID }), action.isAvailable(for: box) else {
            throw DiscoboxError("This action is no longer available. Refresh the box and try again.")
        }
        guard !pendingBoxActions.contains(boxID) else { throw DiscoboxError("An action is already in progress for this box.") }
        recentBoxes.removeValue(forKey: boxID)
        pendingBoxActions.insert(boxID)
        defer { if connection == connectionID { pendingBoxActions.remove(boxID) } }
        if sandboxID == boxID && [.stop, .archive, .unarchive, .purge, .upgrade, .repair].contains(action) { clearSelection() }
        beforeRequest()
        _ = try await client.perform(.init(.boxAction, projectID: projectID, sandboxID: boxID, prompt: name, action: action.rawValue))
        guard connection == connectionID else { return }
        // Avoid reconnecting to a box after an explicit stop/archive/restore.
        if sandboxID == boxID && [.stop, .archive, .unarchive, .purge, .upgrade, .repair].contains(action) { clearSelection() }
        if refreshAfter { await refresh() }
    }

    public struct PurgeResult: Sendable {
        public struct Failure: Sendable {
            public let boxID: String
            public let message: String
        }
        public let purged: [String]
        public let failures: [Failure]
    }
    /// One confirmed manifest, one mutation per box, and one inventory refresh.
    /// The companion rechecks archived state on the server before every purge.
    public func purgeArchivedBoxes(_ boxIDs: [String], connection: UUID, progress: (Int, Int) -> Void = { _, _ in }) async throws -> PurgeResult {
        var seen: Set<String> = []
        let ids = boxIDs.filter { seen.insert($0).inserted }
        guard connection == connectionID, !ids.isEmpty,
              ids.allSatisfy({ id in sandboxes.contains { $0.id == id && BoxAction.purge.isAvailable(for: $0) } && !pendingBoxActions.contains(id) }) else {
            throw DiscoboxError("The selection changed or contains a box that can no longer be purged. Refresh Archived and select again.")
        }
        var purged: [String] = []
        var failures: [PurgeResult.Failure] = []
        for (index, id) in ids.enumerated() {
            guard connection == connectionID, !Task.isCancelled else {
                failures += ids[index...].map { .init(boxID: $0, message: "Not attempted: the connection changed or the operation was cancelled.") }
                break
            }
            do {
                try await performBoxAction(.purge, boxID: id, connection: connection, refreshAfter: false)
                purged.append(id)
            } catch {
                failures.append(.init(boxID: id, message: error.localizedDescription))
            }
            progress(index + 1, ids.count)
        }
        if connection == connectionID, !Task.isCancelled { await refresh() }
        return PurgeResult(purged: purged, failures: failures)
    }

    public func refreshDetails() async {
        guard let client, let projectID, let sandboxID else { return }
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
            } else {
                await refreshScreen()
            }
            let serviceList = try await serviceResult
            guard current == selectionRevision, request == detailsRequest, !Task.isCancelled else { return }
            if services != serviceList.services { services = serviceList.services }
            if servicesObservedAt != serviceList.observedAt { servicesObservedAt = serviceList.observedAt }
            if !canSendInput { inputEnabled = false }
        } catch {
            guard current == selectionRevision, request == detailsRequest, !Task.isCancelled else { return }
            detailError = error.localizedDescription
            inputEnabled = false
        }
    }

    public var hasLiveTerminal: Bool {
        isConnected && selectedBox?.isRunning == true && selectedExec?.acceptsInput == true &&
        inventoryObservedAt == nil && execID != "primary"
    }

    /// Read a pane's saved state without changing keyboard/terminal selection.
    public func fileAccess() throws -> FileAccess {
        guard let client, let projectID, let sandboxID, selectedBox?.isRunning == true else { throw DiscoboxError("Select a running box.") }
        return FileAccess(client: client, project: projectID, box: sandboxID)
    }
    public func openSession(tool: String? = nil, base: String = "", head: String = "") async throws {
        guard !isOpeningSession else { throw DiscoboxError("A session is already being opened.") }
        isOpeningSession = true
        defer { isOpeningSession = false }
        guard let client, let projectID, let sandboxID, selectedBox?.isRunning == true else { throw DiscoboxError("Select a running box.") }
        let selection = selectionRevision
        let payload: JSONValue? = base.isEmpty ? nil : .object(["base": .string(base), "head": .string(head)])
        let created = try await client.decode(.init(tool == nil ? .newAgent : .openTool, projectID: projectID, sandboxID: sandboxID, kind: tool, action: base.isEmpty ? nil : "review", payload: payload), as: Exec.self)
        guard selection == selectionRevision else { return }
        await refreshDetails()
        guard selection == selectionRevision else { return }
        if !execs.contains(where: { $0.id == created.id }) { execs.append(created) }
        await selectExec(created.id)
    }

    public func refreshApprovals() async {
        guard let client, let projectID else { return }
        let connection = connectionID, request = UUID()
        approvalRequest = request
        do {
            let result = try await client.decode(.init(.approvals, projectID: projectID), as: ApprovalInbox.self)
            guard connectionID == connection, approvalRequest == request, !Task.isCancelled else { return }
            let pending = result.approvalRequests.filter { $0.request["status"].string == "pending" }
            if approvals != pending { approvals = pending }
            approvalError = nil
        } catch {
            guard connectionID == connection, approvalRequest == request, !Task.isCancelled else { return }
            approvalError = error.localizedDescription
        }
    }
    public func approvalSecrets() async throws -> [JSONValue] {
        let body = try await operation(.secrets)
        return body["secrets"].array
    }
    public func operation(_ operation: BridgeRequest.Operation, requestID: String? = nil, kind: String? = nil, action: String? = nil, payload: JSONValue? = nil, localPath: String? = nil) async throws -> JSONValue {
        guard let client, let projectID else { throw DiscoboxError("Connect to a server first.") }
        let data = try await client.perform(.init(operation, projectID: projectID, sandboxID: sandboxID, requestID: requestID, kind: kind, action: action, payload: payload, localPath: localPath))
        if data.isEmpty { return .object([:]) }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public func answer(_ item: ApprovalItem, action: String, payload: JSONValue) async throws {
        let connection = connectionID
        _ = try await operation(.answer, requestID: item.id, kind: item.kind, action: action, payload: payload)
        guard connection == connectionID else { return }
        approvalRequest = UUID()
        approvals.removeAll { $0.id == item.id }
        await refreshApprovals()
    }

    public func terminalSnapshot(exec: String) async throws -> TerminalScreen {
        guard let client, let projectID, let sandboxID,
              execs.contains(where: { $0.id == exec }) else { throw DiscoboxError("Terminal is no longer available.") }
        return try await client.decode(.init(.screen, projectID: projectID, sandboxID: sandboxID, execID: exec), as: TerminalScreen.self)
    }

    public func refreshScreen() async {
        if streamsLiveTerminals && hasLiveTerminal { screen = nil; screenError = nil; return }
        guard let client, let projectID, let sandboxID, let execID else { return }
        let current = terminalRevision
        let request = UUID()
        screenRequest = request
        do {
            let result = try await client.decode(.init(.screen, projectID: projectID, sandboxID: sandboxID, execID: execID), as: TerminalScreen.self)
            guard current == terminalRevision, request == screenRequest, !Task.isCancelled else { return }
            screen = result
            screenError = nil
        } catch {
            guard current == terminalRevision, request == screenRequest, !Task.isCancelled else { return }
            screenError = error.localizedDescription
            inputEnabled = false
        }
    }

    public func sendDraft(enter: Bool) async {
        guard !draft.isEmpty else { return }
        guard draft.utf8.count <= 64 * 1024 else {
            inputError = "Send no more than 64 KiB of text at a time."
            return
        }
        let text = draft
        var parts: [InputPart] = [.text(text)]
        if enter { parts.append(.key("Enter")) }
        await send(parts, clearing: text)
    }

    public func sendKey(_ key: String) async { await send([.key(key)]) }

    private func send(_ parts: [InputPart], clearing draftToClear: String? = nil) async {
        guard inputEnabled, canSendInput, !isSending,
              let client, let projectID, let sandboxID, let execID else { return }
        let current = terminalRevision
        isSending = true
        inputError = nil
        defer { isSending = false }
        do {
            _ = try await client.perform(.init(.input, projectID: projectID, sandboxID: sandboxID, execID: execID, input: parts))
            guard current == terminalRevision else { return }
            if let draftToClear, draft == draftToClear { draft = "" }
            await refreshScreen()
        } catch {
            guard current == terminalRevision else { return }
            inputEnabled = false
            inputError = "\(error.localizedDescription) Input may already have arrived. Inspect the screen before sending again."
        }
    }

    public func reconnect() async {
        guard let client else { return }
        let label = endpointLabel, demo = isDemo, box = sandboxID, terminal = execID
        self.client = nil // Preserve the shared transport while reconnecting this workspace.
        await connect(client: client, label: label, demo: demo)
        if isConnected {
            await selectBox(box)
            if let terminal, execs.contains(where: { $0.id == terminal }) { await selectExec(terminal) }
        }
    }
    public func refreshUsage() async {
        guard let client, let projectID, isConnected else { return }
        let connection = connectionID
        let catalog = (try? await harnesses()) ?? cachedHarnesses
        guard connection == connectionID, !Task.isCancelled else { return }
        await usage.refresh(client: client, project: projectID, boxes: sandboxes, configuredHarnesses: catalog)
    }

    public func harnesses(force: Bool = false) async throws -> [Harness] {
        guard let client, let projectID else { throw DiscoboxError("Connect to a server first.") }
        if !force, let readAt = harnessesReadAt, now().timeIntervalSince(readAt) < 60 { return cachedHarnesses }
        let connection = connectionID
        if let harnessLoad {
            let result = try await harnessLoad.value
            guard connection == connectionID else { throw CancellationError() }
            if cachedHarnesses != result { cachedHarnesses = result }
            harnessesReadAt = now()
            return result
        }
        let load = Task.detached(priority: .utility) {
            try await client.decode(.init(.harnesses, projectID: projectID), as: HarnessList.self).harnessConfigs ?? []
        }
        harnessLoad = load
        defer { if connection == connectionID { harnessLoad = nil } }
        let result = try await load.value
        guard connection == connectionID else { throw CancellationError() }
        if cachedHarnesses != result { cachedHarnesses = result }
        harnessesReadAt = now()
        return result
    }
    public func createBox(harness: String, repository: String, prompt: String = "") async throws {
        guard let client, let projectID else { throw DiscoboxError("Connect to a server first.") }
        let current = revision
        do {
            let box = try await client.decode(.init(.createBox, projectID: projectID, harnessID: harness, repository: repository, prompt: prompt), as: Sandbox.self)
            guard current == revision else { throw CancellationError() }
            filter = .all
            searchText = ""
            await refresh()
            guard current == revision else { throw CancellationError() }
            await selectBox(box.id)
        } catch {
            if current == revision { await refresh() }
            throw error
        }
    }
    public func closeShell(_ id: String) async throws {
        guard let client, let projectID, let sandboxID,
              execs.contains(where: { $0.id == id && $0.primary != true && $0.tty }) else { throw DiscoboxError("Select a shell terminal.") }
        let current = selectionRevision
        let connection = connectionID
        _ = try await client.perform(.init(execs.first(where: { $0.id == id })?.isShell == true ? .closeShell : .closeTerminal, projectID: projectID, sandboxID: sandboxID, execID: id))
        if connection == connectionID { recentBoxes.removeValue(forKey: sandboxID) }
        guard current == selectionRevision else { return }
        execs.removeAll { $0.id == id }
        await selectExec(execs.first?.id)
        await refreshDetails()
    }
    public func auditSnapshot(box: String, cursor: JSONValue? = nil) async throws -> AuditSnapshot {
        guard let client, let projectID else { throw DiscoboxError("Connect to a server first.") }
        return try await client.decode(.init(.audit, projectID: projectID, sandboxID: box, payload: cursor), as: AuditSnapshot.self)
    }

    public func openShell() async {
        guard !isOpeningShell else { return }
        guard selectedBox?.isRunning == true, inventoryObservedAt == nil, connectionError == nil, detailError == nil,
              let client, let projectID, let sandboxID else {
            commandError = "Choose a running box to open a shell."
            return
        }
        let current = selectionRevision
        isOpeningShell = true
        commandError = nil
        defer { isOpeningShell = false }
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

    private func clearSelection() {
        selectionLoad?.cancel()
        selectionLoad = nil
        inventoryLoadedAt = nil
        selectionRevision = UUID()
        commandError = nil
        terminalRevision = UUID()
        sandboxID = nil
        execID = nil
        execs = []
        services = []
        screen = nil
        detailError = nil
        screenError = nil
        inputError = nil
        inputEnabled = false
        inventoryObservedAt = nil
        servicesObservedAt = nil
        draft = ""
    }
}
