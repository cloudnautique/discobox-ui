import SwiftUI
import DiscoboxCore

struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    @State private var refreshingBoxes = false
    @State private var showInbox = false
    @State private var boxAction: BoxActionRequest?
    @State private var collapsedRepositories: Set<String> = []
    @AppStorage("groupBoxesByRepository") private var groupByRepository = true
    var body: some View {
        @Bindable var workspace = workspace
        @Bindable var commands = commands
        Group {
            if workspace.isConnecting {
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to Discobox…").font(.title2.weight(.semibold))
                    Text(workspace.endpointLabel == "unix://" ? "Looking for your default local server." : workspace.endpointLabel)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { workspace.disconnect() }.keyboardShortcut(.cancelAction)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.isConnected {
                VStack(spacing: 0) {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Menu {
                                Picker("Filter", selection: $workspace.filter) {
                                    ForEach(Workspace.BoxFilter.allCases) { Text($0.rawValue).tag($0) }
                                }.pickerStyle(.inline)
                                Divider()
                                Toggle("Group by repository", isOn: $groupByRepository)
                            } label: { Text(workspace.filter.rawValue).fontWeight(.semibold) }
                            .menuStyle(.borderlessButton).fixedSize()
                            Spacer()
                            Button { commands.showCreateBox = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New box")
                            if refreshingBoxes { ProgressView().controlSize(.small) }
                            Text("\(workspace.visibleBoxes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                        TextField("Find a box", text: $workspace.searchText)
                            .textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
                        List(selection: Binding(get: { workspace.sandboxID }, set: { id in Task { await workspace.selectBox(id) } })) {
                            if groupByRepository {
                                ForEach(repositoryGroups, id: \.self) { repository in
                                    Section(isExpanded: Binding(
                                        get: { !collapsedRepositories.contains(repository) },
                                        set: { expanded in
                                            if expanded { collapsedRepositories.remove(repository) }
                                            else { collapsedRepositories.insert(repository) }
                                        }
                                    )) {
                                        ForEach(boxes(in: repository)) { box in sidebarRow(box) }
                                    } header: {
                                        HStack(alignment: .top, spacing: 7) {
                                            Image(systemName: "folder").foregroundStyle(.secondary)
                                            Text(repository).fontWeight(.semibold).foregroundStyle(.primary)
                                                .lineLimit(2).help(repository)
                                            Spacer(minLength: 4)
                                            Text("\(boxes(in: repository).count)").monospacedDigit().foregroundStyle(.secondary)
                                        }
                                        .font(.caption).textCase(nil)
                                        .padding(.top, 10).padding(.bottom, 5)
                                        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
                                        .accessibilityLabel("\(repository), \(boxes(in: repository).count) boxes")
                                    }
                                }
                            } else {
                                ForEach(workspace.visibleBoxes) { box in sidebarRow(box) }
                            }
                        }.listStyle(.sidebar).frame(minHeight: 120)
                        .refreshable { await refreshBoxes() }
                        .background(BoxPullToRefresh { await refreshBoxes() })
                        .help("Pull down at the top to refresh, or press ⌘R.")
                        .accessibilityAction(named: Text("Refresh boxes")) { Task { await refreshBoxes() } }
                        Divider()
                        if !commands.focusMode { HarnessUsageSection().layoutPriority(1) }
                    }.frame(minWidth: commands.focusMode ? 0 : 220,
                            idealWidth: commands.focusMode ? 0 : 270,
                            maxWidth: commands.focusMode ? 0 : 360)
                        .clipped().opacity(commands.focusMode ? 0 : 1)
                        .allowsHitTesting(!commands.focusMode)
                        .accessibilityHidden(commands.focusMode)
                        .accessibilityLabel("Boxes")
                    VStack(spacing: 0) {
                        Group {
                            if let box = workspace.selectedBox { BoxWorkspaceView(box: box).id(workspace.connectionID.uuidString + box.id) }
                            else { ContentUnavailableView("Choose a box", systemImage: "shippingbox", description: Text("Your agent sessions, shells, and services in one workspace.")) }
                        }
                        .inspector(isPresented: $commands.showInspector) {
                            if let box = workspace.selectedBox { BoxInspector(box: box) }
                        }.inspectorColumnWidth(min: 220, ideal: 260, max: 340)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    }
                }
                Divider()
                // Status changes must not resize an inline terminal UI while it
                // is drawing its prompt. Keep hints and approvals in one row.
                HStack(spacing: 12) {
                    if !workspace.approvals.isEmpty {
                        Button { showInbox = true } label: { Label("\(workspace.approvals.count) waiting", systemImage: "exclamationmark.circle.fill") }.foregroundStyle(.red).buttonStyle(.borderless)
                    }
                    if workspace.approvalError != nil { Text("Approval inbox unavailable").font(.caption).foregroundStyle(.orange) }
                    if let hint = commands.hint {
                        Label(hint, systemImage: "keyboard")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Circle().fill(workspace.connectionError == nil ? Color.green : .orange).frame(width: 6, height: 6)
                    Text(workspace.isDemo ? "Demo" : (workspace.connectionError == nil ? "Connected" : "Connection interrupted")).font(.caption).foregroundStyle(.secondary)
                    Button { Task { await workspace.reconnect() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reconnect to server")
                        .disabled(workspace.isConnecting)
                }.font(.caption).padding(.horizontal, 14).frame(height: 30).background(.bar)
                }
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(id: "workspace.sidebar", placement: .navigation) {
                        Button { commands.focusMode.toggle() } label: { Label("Toggle sidebar", systemImage: "sidebar.left") }
                            .help("Show or hide boxes")
                    }
                    ToolbarItem(id: "workspace.title", placement: .automatic) {
                        Text(workspace.selectedBox?.displayName ?? "Discobox")
                            .font(.headline).lineLimit(1).truncationMode(.tail)
                    }
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible, placement: .automatic)
                    } else {
                        ToolbarItem(placement: .automatic) { Spacer() }
                    }
                    ToolbarItem(id: "workspace.actions", placement: .automatic) {
                        HStack(spacing: 12) {
                            Menu {
                                if let box = workspace.selectedBox { BoxActionMenu(box: box) { choose($0, box: box) } }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .disabled(workspace.selectedBox == nil).help("Actions for this box")
                            Button { commands.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                                .buttonStyle(.borderless).help("Show or hide box details")
                        }.frame(width: 70)
                    }
                }
                .toolbar(removing: .sidebarToggle)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let error = workspace.connectionError { Notice(text: error, symbol: "wifi.exclamationmark") }
                    if let error = workspace.commandError {
                        HStack { Notice(text: error, symbol: "exclamationmark.triangle"); Button("Dismiss") { workspace.commandError = nil }.padding(.trailing) }
                    }
                }
            } else { WelcomeView() }
        }
        .background(WorkspaceWindowReader(commands: commands))
        .task(id: workspace.connectionID) {
            while !Task.isCancelled {
                await workspace.refreshApprovals()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .sheet(item: $boxAction) { BoxActionSheet(request: $0).environment(workspace) }
        .sheet(isPresented: $showInbox) { ApprovalInboxView(boxID: nil).environment(workspace) }
        .sheet(isPresented: $commands.showTools) { ToolsSheet().environment(workspace) }
        .sheet(isPresented: $commands.showApprovals) { ApprovalInboxView(boxID: nil).environment(workspace) }
        .sheet(isPresented: $commands.showCommands) { CommandsSheet().environment(commands) }
        .sheet(isPresented: $commands.showCreateBox) { NewBoxSheet().environment(workspace) }
        .sheet(isPresented: $commands.choosingBox) { BoxChooser().environment(workspace) }
    }
    private var repositoryGroups: [String] {
        Set(workspace.visibleBoxes.map { $0.repository ?? "No repository" }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func boxes(in repository: String) -> [Sandbox] {
        workspace.visibleBoxes.filter { ($0.repository ?? "No repository") == repository }
    }
    private func openShell(in box: Sandbox) {
        let connection = workspace.connectionID
        Task {
            await workspace.selectBox(box.id)
            guard connection == workspace.connectionID, workspace.sandboxID == box.id else { return }
            await workspace.openShell()
        }
    }
    private func choose(_ action: BoxAction, box: Sandbox) {
        boxAction = BoxActionRequest(box: box, action: action, connection: workspace.connectionID)
    }
    private func sidebarRow(_ box: Sandbox) -> some View {
        BoxRow(box: box).tag(box.id)
            .contextMenu {
                Button("Open workspace") { Task { await workspace.selectBox(box.id) } }
                Button("Open shell") { openShell(in: box) }.disabled(!box.isRunning || workspace.pendingBoxActions.contains(box.id))
                Divider()
                BoxActionMenu(box: box) { choose($0, box: box) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if workspace.filter == .archived && BoxAction.purge.isAvailable(for: box) {
                    Button(role: .destructive) { choose(.purge, box: box) } label: { Label("Purge", systemImage: "trash") }
                } else if BoxAction.archive.isAvailable(for: box) {
                    Button { choose(.archive, box: box) } label: { Label("Archive", systemImage: "archivebox") }.tint(.orange)
                }
                if BoxAction.rename.isAvailable(for: box) {
                    Button { choose(.rename, box: box) } label: { Label("Rename", systemImage: "pencil") }.tint(.gray)
                        .disabled(workspace.pendingBoxActions.contains(box.id))
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if BoxAction.unarchive.isAvailable(for: box) {
                    Button { choose(.unarchive, box: box) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.blue)
                } else {
                    let power: BoxAction = box.isRunning ? .stop : .start
                    if power.isAvailable(for: box) {
                        Button { choose(power, box: box) } label: { Label(power.title, systemImage: power.symbol) }
                            .tint(box.isRunning ? .orange : .green)
                            .disabled(workspace.pendingBoxActions.contains(box.id))
                    }
                    if box.isRunning {
                        Button { openShell(in: box) } label: { Label("Shell", systemImage: "terminal") }.tint(.blue)
                            .disabled(workspace.pendingBoxActions.contains(box.id) || workspace.isOpeningShell)
                    }
                }
            }
    }
    private func refreshBoxes() async {
        guard !refreshingBoxes else { return }
        refreshingBoxes = true
        await workspace.refresh()
        refreshingBoxes = false
    }
}

private struct BoxChooser: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    private var results: [Sandbox] { workspace.switcherBoxes.filter { $0.matchesSearch(query) } }
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Switch box").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            BoxChooserSearch(text: $query, move: move, choose: choose, cancel: { dismiss() })
                .frame(height: 24)
            ScrollViewReader { reader in
                List(selection: $selected) {
                    ForEach(results) { box in
                        Button { select(box.id) } label: { BoxRow(box: box) }.buttonStyle(.plain).tag(box.id)
                    }
                }.listStyle(.inset)
                    .overlay { if results.isEmpty { ContentUnavailableView("No matching boxes", systemImage: "magnifyingglass") } }
                    .onChange(of: selected) { _, id in if let id { reader.scrollTo(id) } }
            }
            Text("↑ ↓ Select   ·   Return Switch   ·   Esc Cancel").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 460, height: 480)
            .onChange(of: results.map(\.id), initial: true) { _, ids in
                if selected == nil || !ids.contains(selected!) { selected = ids.first }
            }
    }
    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selected } ?? 0
        selected = results[min(max(index + delta, 0), results.count - 1)].id
    }
    private func choose() { if let id = selected, results.contains(where: { $0.id == id }) { select(id) } }
    private func select(_ id: String) { Task { await workspace.selectBox(id) }; dismiss() }
}

/// NSTextField's field editor consumes arrows before SwiftUI key handlers.
/// Handle navigation through its editing delegate while keeping typing focused.
private struct BoxChooserSearch: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let choose: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Find a box, harness, or repository"
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BoxChooserSearch
        init(_ parent: BoxChooserSearch) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.choose()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}

struct BoxRow: View {
    let box: Sandbox
    @Environment(Workspace.self) private var workspace
    @State private var showInbox = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(box.isRunning ? Color.green : (box.matchesAttention ? .orange : .secondary.opacity(0.4)))
                .frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(box.displayName).font(.system(.body, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    if workspace.approvals.contains(where: { $0.boxID == box.id }) {
                        Button { showInbox = true } label: { Text("!").font(.headline.bold()).foregroundStyle(.red) }.buttonStyle(.borderless).help("Pending approval requests")
                    }
                }
                HStack {
                    Text(box.harnessName ?? box.config.name ?? "Agent").lineLimit(1)
                    Spacer(minLength: 4)
                    if workspace.pendingBoxActions.contains(box.id) { ProgressView().controlSize(.mini) }
                    else { Text(box.status) }
                }.font(.caption).foregroundStyle(.secondary)
                if let branch = box.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }.padding(.vertical, 5)
        .help([box.displayName, box.repository, box.harnessName, box.branch, box.runtime.errorMessage].compactMap { $0 }.joined(separator: "\n"))
        .sheet(isPresented: $showInbox) { ApprovalInboxView(boxID: box.id).environment(workspace) }
    }
}

struct StatusLabel: View {
    let status: String
    var body: some View {
        Label {
            Text(status).font(.caption)
        } icon: { Circle().fill(color).frame(width: 6, height: 6) }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Status: \(status)")
    }
    private var color: Color {
        switch status.lowercased() {
        case "running": .green
        case "failed", "error": .red
        case "starting", "pending", "awaiting source", "stopping": .orange
        default: .secondary
        }
    }
}

struct Notice: View {
    let text: String
    let symbol: String
    var warning = true
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption).foregroundStyle(warning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(warning ? Color.orange.opacity(0.07) : Color.accentColor.opacity(0.05))
            .textSelection(.enabled)
    }
}

struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox.fill").font(.system(size: 52)).foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("Your boxes. A native workspace.").font(.largeTitle.weight(.semibold))
                Text("Connect to the Discobox server you already use.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            ConnectionSettings().frame(width: 520)
            if let error = workspace.connectionError {
                Notice(text: error, symbol: "exclamationmark.triangle").frame(maxWidth: 600)
            }
            HStack(spacing: 16) {
                Button("Explore demo workspace") {
                    Task {
                        await workspace.connect(client: DemoClient(), label: "Demo workspace", demo: true)
                        await workspace.selectBox("demo-ui")
                    }
                }.buttonStyle(.link)
                if workspace.isConnecting { Button("Cancel") { workspace.disconnect() } }
            }
            Text("Boxes stay available in your CLI and editor.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
