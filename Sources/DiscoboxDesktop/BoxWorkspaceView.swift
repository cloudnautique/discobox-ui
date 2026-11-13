import SwiftUI
import AppKit
import DiscoboxCore

struct BoxWorkspaceView: View {
    let box: Sandbox
    @Environment(Connections.self) private var connections: Connections?
    @Environment(Workspace.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    @Environment(TerminalStore.self) private var terminals
    @State private var showInbox = false
    @State private var closing: TerminalCloseRequest?
    @State private var renaming: PaneRenameRequest?
    @State private var creationAction: BoxActionRequest?
    @AppStorage("confirmShellClose") private var confirmShellClose = true
    private var harness: Exec? { workspace.execs.first(where: { $0.primary == true }) ?? workspace.execs.first(where: { !$0.isShell }) }
    private var harnessConfiguration: Harness? { workspace.cachedHarnesses.first { $0.id == box.config.harnessConfigId } }
    private var companions: [Exec] { workspace.execs.filter { $0.id != harness?.id } }
    private var layout: WorkspaceTabs { commands.layout(for: workspace.connectionID.uuidString + box.id) }
    private var creation: BoxCreation? {
        connections?.creationPins.first { $0.connection == workspace.connectionID && $0.id.box == box.id }
    }
    private var persistenceKey: String {
        let computer = connections?.sessions.first { $0.workspace === workspace }?.id ?? workspace.connectionID.uuidString
        return "workspace." + computer + "." + box.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.detailError { Notice(text: error, symbol: "exclamationmark.triangle") }
            if let warning = box.runningWarning { Notice(text: "Running with a warning: " + warning, symbol: "exclamationmark.triangle") }
            if box.isRunning, let configuration = harnessConfiguration,
               !(box.runtime.agentStatus ?? .null)["harnessConfigCandidate"].string.isEmpty {
                HarnessChangesBanner(box: box, harness: configuration) { manageHarness(configuration) }
            }
            if !box.isRunning { StoppedBoxBar(box: box).id(workspace.connectionID.uuidString + box.id) }
            // The agent is always the first child of this split. Never mount it
            // as a tab or reparent it when opening a supporting tool.
            HSplitView {
                agentPane
                if layout.isSplit { companionArea }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(DiscoboxAppearance.canvas)
        .onChange(of: workspace.execs.map(\.id), initial: true) { _, _ in
            if workspace.sandboxID == box.id, !workspace.execs.isEmpty { layout.reconcile(companions.map { "exec:" + $0.id }) }
        }
        .onChange(of: workspace.execID) { old, id in
            guard workspace.sandboxID == box.id, old != nil, let id else { return }
            if companions.contains(where: { $0.id == id }) {
                layout.reconcile(companions.map { "exec:" + $0.id })
                layout.open("exec:" + id)
            }
        }
        .onChange(of: layout.selected) { _, id in
            if workspace.sandboxID == box.id, id.hasPrefix("exec:") {
                let exec = String(id.dropFirst(5))
                if workspace.execID != exec { Task { if workspace.sandboxID == box.id { await workspace.selectExec(exec) } } }
            }
        }
        .onChange(of: commands.showInspector) { _, visible in if !visible { focusActiveTerminal() } }
        .onChange(of: commands.agentFocusRequest) { focusActiveTerminal(agent: true) }
        .onChange(of: commands.showFiles) { _, show in if show { layout.open("files") } }
        .onChange(of: commands.showAudit) { _, show in if show { layout.open("audit") } }
        .sheet(isPresented: $showInbox) { ApprovalInboxView(boxID: box.id).environment(workspace) }
        .sheet(item: $closing) { request in TerminalCloseSheet(request: request) { closeTerminal(request) } }
        .sheet(item: $renaming) { request in PaneRenameSheet(name: request.name) { layout.rename(request.id, to: $0) } }
        .sheet(item: $creationAction) { BoxActionSheet(request: $0).environment(workspace).id($0.id) }
    }

    private var agentPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Agent", systemImage: "sparkles").fontWeight(.semibold)
                Text(box.harnessName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if workspace.approvals.contains(where: { $0.boxID == box.id }) {
                    Button { showInbox = true } label: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                        .help("Review credential requests").accessibilityLabel("Review credential requests")
                }
                Spacer()
                Menu {
                    if let configuration = harnessConfiguration {
                        Button("Manage harness login and settings…") { manageHarness(configuration) }
                        Divider()
                    }
                    Button("New Shell") { commands.perform(.newShell) }.disabled(!box.isRunning || workspace.isOpeningShell)
                    supportingTools
                } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).help("Agent and workspace actions")
                Button { commands.perform(.focus) } label: {
                    Image(systemName: commands.isAgentMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.help(commands.isAgentMaximized ? "Restore workspace layout" : "Maximize agent")
                    .accessibilityIdentifier("workspace.maximizeAgent")
            }.workspacePaneHeader()
                .overlay(alignment: .bottom) { DiscoboxAppearance.border.frame(height: 1) }
                .onTapGesture { layout.agentFocused = true }
            agentContent
        }.frame(minWidth: 280, minHeight: 180, maxHeight: .infinity)
            .background(WorkspaceSplitPosition(key: persistenceKey, enabled: layout.isSplit, secondaryMinimum: layout.shellsSplit && layout.shellSideBySide ? 720 : 360,
                revision: layout.shellsSplit ? (layout.shellSideBySide ? "columns" : "stack") : "tabs"))
    }
    private func manageHarness(_ configuration: Harness) {
        HarnessSetupWindows.shared.open(configuration, workspace: workspace, connections: connections, commands: commands, sourceBoxID: box.id)
    }
    @ViewBuilder private var agentContent: some View {
        if let harness, box.isRunning, harness.status == "running" {
            ConsoleView(terminal: harness, focused: layout.agentFocused || !layout.isSplit, onFocus: { layout.agentFocused = true }).studioTerminalFrame()
        } else if let creation, creation.phase == .failed {
            ContentUnavailableView {
                Label("Box needs attention", systemImage: "exclamationmark.triangle")
            } description: { Text(creation.message) } actions: {
                Menu("Box Actions") {
                    BoxActionMenu(box: box) { creationAction = .init(box: box, action: $0, connection: workspace.connectionID) }
                }
            }
        } else if let creation, creation.phase == .starting {
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting your box…").font(.headline)
                Text(box.preparationStatus?.isEmpty == false ? box.preparationStatus! : box.status).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let harness, !["starting", "repairing"].contains(box.runtime.displayState ?? "") {
            ConsoleView(terminal: harness, focused: layout.agentFocused || !layout.isSplit, onFocus: { layout.agentFocused = true }).studioTerminalFrame()
        } else if creation != nil {
            ProgressView("Waiting for the agent…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if ["starting", "repairing"].contains(box.runtime.displayState ?? "") {
            VStack(spacing: 12) { ProgressView(); Text(box.preparationStatus ?? "Preparing the box…").font(.callout).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { ContentUnavailableView("No harness terminal", systemImage: "terminal", description: Text("A startup hook or harness may have exited. You can still open a shell to inspect this box.")) }
    }
    @ViewBuilder private var companionArea: some View {
        if layout.shellsSplit {
            if layout.shellSideBySide { HSplitView { splitPanes }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { VSplitView { splitPanes }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else {
            VStack(spacing: 0) {
                tabBar
                paneContent(layout.selected)
            }.frame(minWidth: 280, minHeight: 180, maxHeight: .infinity)
        }
    }
    private var splitPanes: some View {
        ForEach(layout.visibleCompanions, id: \.self) { id in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label(title(id), systemImage: symbol(id)).lineLimit(1)
                    Spacer(minLength: 4)
                    if layout.visibleCompanions.first == id { shellActions }
                    Button { close(id) } label: { Image(systemName: "xmark").font(.caption2) }
                        .help("Close " + title(id)).accessibilityLabel("Close " + title(id))
                }.workspacePaneHeader()
                    .overlay(alignment: .bottom) { paneBorder(id) }
                    .contentShape(Rectangle()).onTapGesture { layout.open(id) }
                    .contextMenu { sessionMenu(id) }
                paneContent(id)
            }.frame(minWidth: 280, minHeight: 180, maxHeight: .infinity)
                .background(WorkspaceSplitPosition(key: persistenceKey + (layout.shellSideBySide ? ".horizontal" : ".vertical"), enabled: layout.visibleCompanions.first == id, fraction: 0.5, minimum: layout.shellSideBySide ? 360 : 180, secondaryMinimum: layout.shellSideBySide ? 360 : 180))
        }
    }
    private var tabBar: some View {
        HStack(spacing: 8) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(layout.companionIDs, id: \.self) { id in
                            HStack(spacing: 7) {
                                Button { layout.open(id) } label: { Label(title(id), systemImage: symbol(id)).lineLimit(1) }.buttonStyle(.plain)
                                Button { close(id) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                    .buttonStyle(.plain).help("Close " + title(id)).accessibilityLabel("Close " + title(id))
                            }.padding(.horizontal, 10).padding(.vertical, 7)
                                .background(layout.selected == id ? DiscoboxAppearance.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .accessibilityElement(children: .contain)
                                .accessibilityAddTraits(layout.selected == id ? .isSelected : [])
                                .id(id).contextMenu { sessionMenu(id) }
                        }
                    }
                }.onChange(of: layout.selected, initial: true) { _, id in reader.scrollTo(id) }
            }
            shellActions
        }.workspacePaneHeader().overlay(alignment: .bottom) { paneBorder(layout.selected) }
    }
    private var shellActions: some View {
        HStack(spacing: 9) {
            if workspace.isOpeningShell { ProgressView().controlSize(.mini) }
            Button { commands.perform(.newShell) } label: { Image(systemName: "plus") }
                .disabled(!box.isRunning || workspace.isOpeningShell).help("New shell").accessibilityIdentifier("workspace.newShell")
            Menu {
                if layout.shellsSplit {
                    Button("Merge into Tabs") { layout.mergeShells() }
                    Button("Stack Shells") { layout.shellSideBySide = false }
                    Button("Shells Side by Side") { layout.shellSideBySide = true }
                } else {
                    ForEach(layout.terminalIDs.filter { $0 != layout.selected }, id: \.self) { id in
                        Button("Split with " + title(id)) { layout.split(with: id) }
                    }
                    Button("New Shell and Split") { newSplitShell() }.disabled(!box.isRunning || workspace.isOpeningShell)
                }
            } label: { Label(layout.shellsSplit ? "Merge" : "Split", systemImage: layout.shellsSplit ? "rectangle" : "rectangle.split.1x2") }
            primaryAction: {
                if layout.shellsSplit { layout.mergeShells() }
                else if let id = layout.terminalIDs.first(where: { $0 != layout.selected }), layout.selected.hasPrefix("exec:") { layout.split(with: id) }
                else { newSplitShell() }
            }.menuIndicator(.hidden).fixedSize()
                .disabled(!layout.selected.hasPrefix("exec:")).help("Arrange shell sessions; the agent stays visible")
            Menu {
                if layout.shellsSplit {
                    ForEach(layout.companionIDs.filter { !layout.visibleCompanions.contains($0) }, id: \.self) { id in
                        Button(title(id)) { layout.open(id) }
                    }
                    Divider()
                }
                supportingTools
            } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).help("Files, changes and additional tools")
            Button { commands.toggleShells() } label: { Image(systemName: "chevron.right") }
                .help("Hide shells without stopping them (" + commands.appShortcuts[.toggleShells] + ")")
                .accessibilityLabel("Hide shell area").accessibilityIdentifier("workspace.hideShells")
        }.foregroundStyle(.secondary)
    }
    @ViewBuilder private var supportingTools: some View {
        Button("Files") { layout.open("files") }
        Button("Changes") { commands.perform(.changes) }.disabled(!box.isRunning)
        Button("Audit") { layout.open("audit") }
        Button("Tools & Additional Agent…") { commands.showTools = true }
    }
    private func paneBorder(_ id: String) -> some View {
        (!layout.agentFocused && layout.selected == id ? DiscoboxAppearance.accent.opacity(0.4) : DiscoboxAppearance.border).frame(height: 1)
    }
    private func paneContent(_ id: String) -> some View {
        Group {
            if let terminal = companions.first(where: { "exec:" + $0.id == id }) {
                ConsoleView(terminal: terminal, focused: !layout.agentFocused && layout.selected == id, onFocus: { layout.open(id) }).studioTerminalFrame()
            } else if id == "audit" { AuditView(boxID: box.id, focusSearch: !layout.agentFocused) }
            else if id == "files" { FilesView() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ToolPaneFocus(active: !layout.agentFocused && id == layout.selected && id == "files"))
            .simultaneousGesture(TapGesture().onEnded { layout.open(id) })
    }
    @ViewBuilder private func sessionMenu(_ id: String) -> some View {
        Button("Select Tab") { layout.open(id) }
        if id.hasPrefix("exec:") {
            Button("Rename Tab…") { renaming = .init(id: id, name: title(id)) }
            if layout.shellsSplit { Button("Merge into Tabs") { layout.mergeShells() } }
            else {
                ForEach(layout.terminalIDs.filter { $0 != id }, id: \.self) { other in
                    Button("Split with " + title(other)) { layout.open(id); layout.split(with: other) }
                }
            }
        }
        Divider()
        Button("Close " + title(id)) { close(id) }
    }
    private func title(_ id: String) -> String {
        if let name = layout.names[id] { return name }
        switch id {
        case "audit": return "Audit"
        case "files": return "Files"
        default:
            guard let exec = companions.first(where: { "exec:" + $0.id == id }) else { return "Terminal" }
            let matching = companions.filter { $0.title == exec.title }
            return matching.count > 1 ? exec.title + " " + String((matching.firstIndex(of: exec) ?? 0) + 1) : exec.title
        }
    }
    private func symbol(_ id: String) -> String { id == "audit" ? "list.bullet.rectangle" : id == "files" ? "folder" : "terminal" }
    private func focusActiveTerminal(agent: Bool = false) {
        let exec = agent || layout.agentFocused || !layout.isSplit ? harness?.id : (layout.selected.hasPrefix("exec:") ? String(layout.selected.dropFirst(5)) : nil)
        guard let exec else { return }
        terminals.focus(.init(connection: workspace.connectionID, endpoint: workspace.transportEndpoint, project: workspace.projectID ?? "", box: box.id, exec: exec, demo: workspace.isDemo))
    }
    private func newSplitShell() {
        let target = workspace, generation = workspace.connectionID, layout = layout
        let previous = layout.selected
        Task {
            await target.openShell()
            guard target.connectionID == generation, target.sandboxID == box.id, let exec = target.execID,
                  exec != String(previous.dropFirst(5)), target.execs.contains(where: { $0.id == exec && $0.isShell }) else { return }
            layout.reconcile(target.execs.filter { $0.id != harness?.id }.map { "exec:" + $0.id })
            layout.open(previous); layout.split(with: "exec:" + exec)
        }
    }
    private func close(_ id: String) {
        if let exec = companions.first(where: { "exec:" + $0.id == id }) {
            let request = TerminalCloseRequest(terminal: exec, box: box.id, connection: workspace.connectionID)
            if exec.isShell && !confirmShellClose { closeTerminal(request) } else { closing = request }
        } else { layout.close(id) }
    }
    private func closeTerminal(_ request: TerminalCloseRequest) {
        let target = workspace
        Task {
            guard target.connectionID == request.connection, target.sandboxID == request.box else {
                target.commandError = "The terminal or connection changed. Close the terminal again from its current box."
                return
            }
            let identity = TerminalIdentity(connection: request.connection, endpoint: target.transportEndpoint, project: target.projectID ?? "", box: request.box, exec: request.terminal.id, demo: target.isDemo)
            do { try await target.closeShell(request.terminal.id); terminals.reconnect(identity) }
            catch { target.commandError = error.localizedDescription }
        }
    }
}

private struct PaneRenameRequest: Identifiable { let id: String; let name: String }
private struct PaneRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let save: (String) -> Void
    var body: some View {
        StudioConfirmation(title: "Rename shell tab", symbol: "terminal", width: 420) {
            TextField("Tab name", text: $name).textFieldStyle(.roundedBorder)
            Text("This label is remembered while this box is open in the app.").font(.caption).foregroundStyle(.secondary)
        } footer: {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save(name); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct TerminalCloseRequest: Identifiable {
    let id = UUID()
    let terminal: Exec
    let box: String
    let connection: UUID
}

struct TerminalCloseSheet: View {
    let request: TerminalCloseRequest
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("confirmShellClose") private var confirmShellClose = true
    @State private var dontAskAgain = false
    var body: some View {
        StudioConfirmation(title: "Close \(request.terminal.title)?", symbol: "terminal", destructive: true) {
            VStack(alignment: .leading, spacing: 16) {
                Text("This ends the terminal’s running process. Other terminals and the box stay running.").foregroundStyle(.secondary)
                if request.terminal.isShell {
                    Toggle("Don’t ask again when closing shells", isOn: $dontAskAgain)
                    Text("Turn confirmation back on in Settings → Appearance → Terminals.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Close Terminal", role: .destructive) {
                    if request.terminal.isShell && dontAskAgain { confirmShellClose = false }
                    confirm(); dismiss()
                }.buttonStyle(.borderedProminent).tint(.red).keyboardShortcut(.defaultAction).accessibilityIdentifier("terminal.confirmClose")
            }
        }
    }
}

/// Give a nonterminal pane keyboard ownership when cycling from a terminal.
private struct ToolPaneFocus: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        guard active != view.active else { return }
        view.active = active
        if active {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.active, let window = view.window else { return }
                // A mouse click may already have focused a search field or file
                // list. Only take keyboard ownership away from the terminal.
                if window.firstResponder is GhosttyTerminalView || window.firstResponder === window || window.firstResponder == nil {
                    window.makeFirstResponder(view)
                }
            }
        }
    }
    final class Anchor: NSView {
        var active = false
        override var acceptsFirstResponder: Bool { true }
    }
}

private extension View {
    func workspacePaneHeader() -> some View {
        self.font(.system(size: 12)).buttonStyle(.borderless)
            .padding(.horizontal, 14).frame(height: 42).background(DiscoboxAppearance.chrome)
    }
    func studioTerminalFrame() -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DiscoboxAppearance.border.opacity(0.5), lineWidth: 1) }
            .padding(DiscoboxAppearance.terminalInset).background(DiscoboxAppearance.canvas)
    }
}

struct ConsoleView: View {
    let terminal: Exec
    var focused: Bool? = nil
    var onFocus: (() -> Void)? = nil
    @Environment(Workspace.self) private var workspace
    @State private var savedScreen: TerminalScreen?
    @State private var error: String?
    private var live: Bool { workspace.isConnected && !workspace.pendingBoxActions.contains(workspace.sandboxID ?? "") && workspace.selectedBox?.isRunning == true && terminal.acceptsInput && workspace.inventoryObservedAt == nil }
    var body: some View {
        VStack(spacing: 0) {
            if live, let project = workspace.projectID, let box = workspace.sandboxID {
                LiveTerminal(identity: TerminalIdentity(connection: workspace.connectionID,
                    endpoint: workspace.transportEndpoint, project: project, box: box, exec: terminal.id, demo: workspace.isDemo), focused: focused ?? (workspace.execID == terminal.id), onFocus: {
                        if let onFocus { onFocus(); return }
                        guard workspace.execID != terminal.id else { return }
                        Task { await workspace.selectExec(terminal.id) }
                    })
            } else if let screen = savedScreen {
                if workspace.selectedBox?.isRunning != false {
                    Notice(text: "Saved terminal state · Read only", symbol: "clock", warning: false)
                }
                TerminalTextView(text: screen.text).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(terminal.isShell ? "Shell ended" : "Terminal unavailable", systemImage: "terminal",
                    description: Text(terminal.isShell ? "This shell is no longer running. Close its tab or use + to open a new shell." : (error ?? "No live terminal is available. Stopped boxes are not started automatically.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(workspace.connectionID)-\(workspace.sandboxID ?? "")-\(terminal.id)-\(live)-\(terminal.status)") {
            savedScreen = nil; error = nil
            guard !live else { return }
            do {
                let screen = try await workspace.terminalSnapshot(exec: terminal.id)
                guard !Task.isCancelled else { return }
                savedScreen = screen
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct BoxInspector: View {
    let box: Sandbox
    @Environment(Workspace.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @State private var showResources = false
    var body: some View {
        Form {
            Section("Box") {
                LabeledContent("Status") { StatusLabel(status: box.status) }
                detail("ID", box.id)
                detail("Pool", box.poolId)
                detail("Platform", box.platform)
            }
            Section("Agent") {
                detail("Model", box.config.model)
                detail("Harness", box.config.harnessConfigId)
                LabeledContent("Manager API access", value: box.discoboxApi == true ? "Enabled" : workspace.approvals.contains(where: { $0.kind == "apiAccess" && $0.boxID == box.id }) ? "Pending approval" : box.discoboxApi == nil ? "Not reported" : "Off")
            }
            Section("Resources") {
                LabeledContent("CPU cores", value: ResourceValue.cpu(box.resourceCPU))
                LabeledContent("Memory", value: ResourceValue.bytes(box.resourceMemory))
                LabeledContent("Disk", value: ResourceValue.bytes(box.resourceDisk))
                if let observed = box.resourceObservedAt { Text("Measured \(observed, style: .relative) ago").font(.caption).foregroundStyle(.secondary) }
                Text("Disk includes workspace data. Shared caches belong to the pool.").font(.caption).foregroundStyle(.secondary)
                Button("Manage Pool Resources…") { showResources = true }
            }
            Section("Observed state") {
                detail("Existence", box.runtime.state)
                detail("Power", box.runtime.runtimeState ?? "Not observed")
                detail("Last activity", box.runtime.lastActiveAt)
            }
            if let tags = box.meta?.tags, !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags.keys.sorted(), id: \.self) { key in detail(key, tags[key]) }
                }
            }
            Section {
                Text("This box belongs to your Discobox server. Closing this window leaves it running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden).background(DiscoboxAppearance.canvas)
        .sheet(isPresented: $showResources) {
            PoolResourcesView(computer: connections?.sessions.first { $0.workspace === workspace }?.profile.displayName ?? workspace.endpointLabel, initialPoolID: box.poolId)
        }
    }

    @ViewBuilder private func detail(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
