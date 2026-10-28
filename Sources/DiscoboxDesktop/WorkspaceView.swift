import SwiftUI
import DiscoboxCore

struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    @State private var refreshingBoxes = false
    @State private var showInbox = false
    @State private var boxAction: BoxActionRequest?
    @AppStorage("collapsedRepositoryGroups") private var collapsedRepositoryData = "[]"
    private var collapsedRepositories: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: Data(collapsedRepositoryData.utf8))) ?? []) }
        nonmutating set { collapsedRepositoryData = String(data: (try? JSONEncoder().encode(newValue.sorted())) ?? Data(), encoding: .utf8) ?? "[]" }
    }
    @AppStorage("boxGrouping") private var grouping = "repository"
    @AppStorage("boxGroupingTagKey") private var groupingTagKey = ""
    @AppStorage("inspectorCompactRail") private var compactRail = true
    private var inspectorRailVisible: Bool { compactRail && !commands.showInspector && workspace.selectedBox != nil }
    @State private var selectedTags: Set<String> = []
    @State private var matchAnyTag = false
    @State private var showTagFilters = false
    private var tagKeys: [String] { Set(workspace.sandboxes.flatMap { Array(($0.meta?.tags ?? [:]).keys) }).sorted() }
    private var tagChoices: [String] {
        Set(workspace.sandboxes.flatMap { box in
            (box.meta?.tags ?? [:]).flatMap { key, value in value.isEmpty ? [key] : [key, key + "=" + value] }
        }).sorted()
    }
    private func collapseKey(_ group: String) -> String { grouping == "repository" ? group : grouping + ":" + groupingTagKey + ":" + group }

    var body: some View {
        @Bindable var workspace = workspace
        @Bindable var commands = commands
        let waiting = Set(workspace.approvals.map(\.boxID))
        let visibleBoxes = workspace.visibleBoxes.filter { BoxOrganization.matches(tags: $0.meta?.tags ?? [:], selectors: selectedTags, matchAny: matchAnyTag) }.enumerated().sorted { lhs, rhs in
            func rank(_ box: Sandbox) -> Int { waiting.contains(box.id) || box.matchesAttention ? 0 : (box.isRunning ? 1 : 2) }
            let left = rank(lhs.element), right = rank(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        let groupedBoxes = Dictionary(grouping: visibleBoxes) { BoxOrganization.group($0, by: grouping, tagKey: groupingTagKey) }
        let repositories = groupedBoxes.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
                                Menu("Group by") {
                                    Picker("Group by", selection: $grouping) {
                                        Text("Repository").tag("repository")
                                        Text("Harness").tag("harness")
                                        Text("State").tag("state")
                                        Text("None").tag("none")
                                    }
                                    Menu("Tag…") {
                                        ForEach(tagKeys, id: \.self) { key in
                                            Button { groupingTagKey = key; grouping = "tag" } label: {
                                                if grouping == "tag" && groupingTagKey == key { Label(key, systemImage: "checkmark") }
                                                else { Text(key) }
                                            }
                                        }
                                    }.disabled(tagKeys.isEmpty)
                                }
                                Button("Filter by tag…") { showTagFilters = true }.disabled(tagChoices.isEmpty)
                                Button("Clear tag filters") { selectedTags.removeAll() }.disabled(selectedTags.isEmpty)
                            } label: { Text(workspace.filter.rawValue).fontWeight(.semibold) }
                            .menuStyle(.borderlessButton).fixedSize()
                            Spacer()
                            Button { commands.showCreateBox = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New box")
                            if refreshingBoxes { ProgressView().controlSize(.small) }
                            Text("\(visibleBoxes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                        TextField("Find a box", text: $workspace.searchText)
                            .textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
                        if !selectedTags.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 5) {
                                    Text(matchAnyTag ? "Any:" : "All:").font(.caption2).foregroundStyle(.secondary)
                                    ForEach(selectedTags.sorted(), id: \.self) { tag in
                                        Button { selectedTags.remove(tag) } label: {
                                            HStack(spacing: 4) { Text(tag); Image(systemName: "xmark").font(.system(size: 8)) }
                                                .font(.caption).padding(.horizontal, 7).padding(.vertical, 4)
                                                .background(.quaternary, in: Capsule())
                                        }.buttonStyle(.plain).help("Remove filter: " + tag)
                                    }
                                }
                            }.padding(.horizontal, 10).padding(.bottom, 6)
                        }
                        List(selection: Binding(get: { workspace.sandboxID }, set: { id in Task { await workspace.selectBox(id) } })) {
                            if grouping != "none" {
                                ForEach(repositories, id: \.self) { repository in
                                    let boxes = groupedBoxes[repository] ?? []
                                    Button {
                                        if collapsedRepositories.contains(collapseKey(repository)) { collapsedRepositories.remove(collapseKey(repository)) }
                                        else { collapsedRepositories.insert(collapseKey(repository)) }
                                    } label: {
                                        RepositoryGroupHeader(repository: repository, count: boxes.count, symbol: grouping == "repository" ? "folder" : grouping == "harness" ? "terminal" : grouping == "tag" ? "tag" : "circle",
                                                              expanded: !collapsedRepositories.contains(collapseKey(repository)))
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 0))
                                    .accessibilityLabel("\(repository), \(boxes.count) boxes")
                                    .accessibilityValue(collapsedRepositories.contains(collapseKey(repository)) ? "Collapsed" : "Expanded")
                                    if !collapsedRepositories.contains(collapseKey(repository)) {
                                        ForEach(boxes) { box in sidebarRow(box) }
                                    }
                                }
                            } else {
                                ForEach(visibleBoxes) { box in sidebarRow(box) }
                            }
                        }.listStyle(.sidebar).frame(minHeight: 120)
                        .refreshable { await refreshBoxes() }
                        .background(BoxPullToRefresh { await refreshBoxes() })
                        .help("Pull down at the top to refresh, or press ⌘R.")
                        .accessibilityAction(named: Text("Refresh boxes")) { Task { await refreshBoxes() } }
                        if !commands.focusMode { HarnessUsageSection().layoutPriority(1) }
                    }.frame(minWidth: commands.focusMode ? 0 : 220,
                            idealWidth: commands.focusMode ? 0 : 270,
                            maxWidth: commands.focusMode ? 0 : 360)
                        .clipped().opacity(commands.focusMode ? 0 : 1)
                        .allowsHitTesting(!commands.focusMode)
                        .accessibilityHidden(commands.focusMode)
                        .accessibilityLabel("Boxes")
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Group {
                                if let box = workspace.selectedBox { BoxWorkspaceView(box: box).id(workspace.connectionID.uuidString + box.id) }
                                else { ContentUnavailableView("Choose a box", systemImage: "shippingbox", description: Text("Your agent sessions, shells, and services in one workspace.")) }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            if inspectorRailVisible, let box = workspace.selectedBox {
                                ServiceRail(box: box).id(workspace.connectionID.uuidString + box.id)
                            }
                        }
                        .inspector(isPresented: $commands.showInspector) {
                            if let box = workspace.selectedBox { WorkspaceInspector(box: box).id(workspace.connectionID.uuidString + box.id) }
                        }.inspectorColumnWidth(min: 320, ideal: 360, max: 480)
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
                    if workspace.endpointLabel.hasPrefix("discobox://") || workspace.endpointLabel.hasPrefix("iroh://") {
                        Text(URLComponents(string: workspace.endpointLabel)?.host ?? "Remote")
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                            .help(workspace.endpointLabel)
                    }
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
                            Button { commands.toggleInspector() } label: { Image(systemName: "sidebar.right") }
                                .buttonStyle(.borderless).help("Toggle inspector (" + commands.appShortcuts[.toggleInspector] + ")")
                                .opacity(inspectorRailVisible ? 0 : 1)
                                .disabled(inspectorRailVisible)
                                .allowsHitTesting(!inspectorRailVisible)
                                .accessibilityHidden(inspectorRailVisible)
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
        .background { WorkspaceDialogs() }
        .sheet(isPresented: $showTagFilters) {
            TagFilterSheet(choices: tagChoices, selected: $selectedTags, matchAny: $matchAnyTag)
        }
        .onChange(of: workspace.connectionID) { _, _ in selectedTags.removeAll() }
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

private struct WorkspaceDialogs: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    var body: some View {
        @Bindable var commands = commands
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $commands.showCreateBox) { NewBoxSheet().environment(workspace) }
            .sheet(isPresented: $commands.choosingBox) { BoxChooser().environment(workspace) }
    }
}

private struct BoxChooser: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    private var results: [Sandbox] { workspace.switcherBoxes.filter { $0.matchesSearch(query) } }
    var body: some View {
        let matches = results
        let waiting = Set(workspace.approvals.map(\.boxID))
        VStack(alignment: .leading) {
            HStack { Text("Switch box").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            BoxChooserSearch(text: $query, move: move, choose: choose, cancel: { dismiss() })
                .frame(height: 24)
            ScrollViewReader { reader in
                List(selection: $selected) {
                    ForEach(matches) { box in
                        Button { select(box.id) } label: { BoxChooserRow(box: box, needsAttention: box.matchesAttention || waiting.contains(box.id)) }.buttonStyle(.plain).tag(box.id)
                    }
                }.listStyle(.inset)
                    .overlay { if matches.isEmpty { ContentUnavailableView("No matching boxes", systemImage: "magnifyingglass") } }
                    .onChange(of: selected) { _, id in if let id { reader.scrollTo(id) } }
            }
            Text("↑ ↓ Select   ·   Return Switch   ·   Esc Cancel").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 460, height: 480)
            .onChange(of: matches.map(\.id), initial: true) { _, ids in
                if selected == nil || !ids.contains(selected!) { selected = ids.first }
            }
    }
    private func move(_ delta: Int) {
        let matches = results
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selected } ?? 0
        selected = matches[min(max(index + delta, 0), matches.count - 1)].id
    }
    private func choose() { if let id = selected, results.contains(where: { $0.id == id }) { select(id) } }
    private func select(_ id: String) { Task { await workspace.selectBox(id) }; dismiss() }
}

/// The switcher has no per-row sheets, approval buttons, or context menus.
private struct BoxChooserRow: View {
    let box: Sandbox
    let needsAttention: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if needsAttention {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
                    .accessibilityLabel("Needs attention").padding(.top, 3)
            } else {
                Circle().fill(box.isRunning ? Color.green : .secondary.opacity(0.5))
                    .frame(width: 7, height: 7).padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(box.displayName).fontWeight(.medium).lineLimit(2)
                Text([box.harnessName, box.repository, box.branch].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(box.status).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
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

private struct RepositoryGroupHeader: View {
    let repository: String
    let count: Int
    let symbol: String
    let expanded: Bool
    private var parts: [String] { repository.split(separator: "/").map(String.init) }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold)).frame(width: 10)
            Image(systemName: symbol).foregroundStyle(.secondary)
            if symbol == "folder" && parts.count > 1 {
                (Text(parts.dropLast().joined(separator: "/") + " / ").foregroundColor(.secondary)
                 + Text(parts.last ?? repository).bold())
                    .lineLimit(1).truncationMode(.middle)
            } else { Text(repository).bold().lineLimit(1) }
            Spacer(minLength: 2)
            Text(String(count)).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .font(.caption).padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle()).help(repository)
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
                    if let branch = box.branch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption2).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 110, alignment: .trailing)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
        .accessibilityValue(box.status)
        .help([box.displayName, box.status, box.repository, box.harnessName, box.branch, box.runtime.errorMessage].compactMap { $0 }.joined(separator: "\n"))
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

private struct TagFilterSheet: View {
    let choices: [String]
    @Binding var selected: Set<String>
    @Binding var matchAny: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Filter by tag").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Picker("Matching", selection: $matchAny) {
                Text("Match all").tag(false)
                Text("Match any").tag(true)
            }.pickerStyle(.segmented)
            TextField("Find a tag", text: $search).textFieldStyle(.roundedBorder)
            List(choices.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { tag in
                Toggle(tag, isOn: Binding(get: { selected.contains(tag) }, set: { on in
                    if on { selected.insert(tag) } else { selected.remove(tag) }
                })).toggleStyle(.checkbox)
            }
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear filters") { selected.removeAll() }.disabled(selected.isEmpty)
            }
        }.padding(20).frame(width: 420, height: 460)
    }
}
