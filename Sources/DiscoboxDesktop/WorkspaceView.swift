import SwiftUI
import DiscoboxCore

struct WorkspaceView: View {
    @Environment(Connections.self) private var connections: Connections
    @Environment(ConnectionSession.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    @Environment(BoxActionPresentation.self) private var boxActions: BoxActionPresentation
    @State private var refreshingBoxes = false
    @State private var contentWidth: CGFloat = 0
    @State private var sidebarWidth: CGFloat = 282
    @State private var responsiveRail = false
    @State private var showInbox = false
    @AppStorage("boxGrouping") private var grouping = "repository"
    @AppStorage("boxGroupingTagKey") private var groupingTagKey = ""
    @AppStorage("inspectorCompactRail") private var compactRail = true
    private var inspectorRailVisible: Bool { (compactRail || responsiveRail) && !commands.showInspector && workspace.selection.selectedBox != nil }
    @State private var showTagFilters = false
    private var currentFilter: BoxFilter {
        get { connections.browser.filter }
        nonmutating set { connections.browser.filter = newValue }
    }
    private var selectedTags: Set<String> {
        get { connections.browser.selectedTags }
        nonmutating set { connections.browser.selectedTags = newValue }
    }
    private var matchAnyTag: Bool {
        get { connections.browser.matchAnyTag }
        nonmutating set { connections.browser.matchAnyTag = newValue }
    }
    private var filterBinding: Binding<BoxFilter> { Binding(get: { currentFilter }, set: { currentFilter = $0 }) }
    private var searchBinding: Binding<String> { Binding(get: { connections.browser.searchText }, set: {
        connections.browser.searchText = $0
    }) }
    private var tagBinding: Binding<Set<String>> { Binding(get: { selectedTags }, set: { selectedTags = $0 }) }
    private var matchAnyBinding: Binding<Bool> { Binding(get: { matchAnyTag }, set: { matchAnyTag = $0 }) }
    private var activityBinding: Binding<BoxActivityFilter?> {
        Binding(get: { connections.browser.activityFilter }, set: {
            connections.browser.activityFilter = $0
        })
    }
    private var activityCounts: (needsYou: Int, working: Int) {
        let snapshot = connections.browserSnapshot
        return (snapshot.needsYouCount, snapshot.workingCount)
    }
    private var archiveCount: Int { connections.browser.archivedSelection.count }
    private var selectedCreation: Bool {
        return connections.creationPins.contains { $0.connection == workspace.connectionState.connectionID && $0.id.box == workspace.selection.sandboxID }
    }
    private var organizationBoxes: [Sandbox] { connections.sessions.filter { $0.connectionState.isConnected }.flatMap { $0.inventory.sandboxes } }
    private var tagKeys: [String] { Set(organizationBoxes.flatMap { Array(($0.meta?.tags ?? [:]).keys) }).sorted() }
    private var tagChoices: [String] {
        Set(organizationBoxes.flatMap { box in
            (box.meta?.tags ?? [:]).flatMap { key, value in value.isEmpty ? [key] : [key, key + "=" + value] }
        }).sorted()
    }
    var body: some View {
        @Bindable var commands = commands
        Group {
            if workspace.connectionState.isConnecting && connections.sessions.contains(where: { $0 !== workspace && $0.connectionState.isConnected }) != true {
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to Discobox…").font(.title2.weight(.semibold))
                    Text(workspace.connectionState.endpointLabel == "unix://" ? "Looking for your default local server." : workspace.connectionState.endpointLabel)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { connections.disconnect(connections.activeID) }.keyboardShortcut(.cancelAction)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DiscoboxAppearance.canvas)
            } else if workspace.connectionState.isConnected || connections.sessions.contains(where: { $0.connectionState.isConnected }) == true {
                VStack(spacing: 0) {
                HSplitView {
                    sidebar
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Group {
                                if currentFilter == .archived && archiveCount != 1 && !selectedCreation {
                                    ContentUnavailableView {
                                        Label(archiveCount == 0 ? "Archived boxes" : "\(archiveCount) archived boxes selected", systemImage: "archivebox")
                                    } description: {
                                        Text("Command-click to select boxes, or Shift-click to select a range. Purging permanently deletes their workspace data.")
                                    }
                                } else if let box = workspace.selection.selectedBox { BoxWorkspaceView(box: box).id(workspace.connectionState.connectionID.uuidString + box.id) }
                                else { ContentUnavailableView("Choose a box", systemImage: "shippingbox", description: Text("Your agent sessions, shells, and services in one workspace.")) }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            if inspectorRailVisible, let box = workspace.selection.selectedBox {
                                ServiceRail(box: box).id(workspace.connectionState.connectionID.uuidString + box.id)
                            }
                        }
                        .inspector(isPresented: $commands.showInspector) {
                            if let box = workspace.selection.selectedBox { WorkspaceInspector(box: box).id(workspace.connectionState.connectionID.uuidString + box.id) }
                        }.inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    }.id(workspace.connectionState.connectionID)
                }
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in contentWidth = width; fitInspector() }
                })
                .onChange(of: commands.showInspector) { fitInspector() }
                .onChange(of: commands.currentLayout?.isSplit) { fitInspector() }
                .onChange(of: commands.currentLayout?.shellSideBySide) { fitInspector() }
                Divider()
                // Status changes must not resize an inline terminal UI while it
                // is drawing its prompt. Keep hints and approvals in one row.
                HStack(spacing: 12) {
                    if !workspace.approvalStore.approvals.isEmpty {
                        Button { showInbox = true } label: { Label("\(workspace.approvalStore.approvals.count) waiting", systemImage: "exclamationmark.circle.fill") }.foregroundStyle(.red).buttonStyle(.borderless)
                    }
                    if workspace.approvalStore.approvalError != nil { Text("Approval inbox unavailable").font(.caption).foregroundStyle(.orange) }
                    if let hint = commands.hint {
                        Label(hint, systemImage: "keyboard")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    ConnectionStatusBadge(workspace: workspace)
                    Text(connections.active.profile.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(workspace.connectionState.endpointLabel)
                    Button { Task { await workspace.reconnect() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reconnect to server")
                        .disabled(workspace.connectionState.isConnecting || workspace.connectionState.recovery.isAttempting)
                }.font(.caption).padding(.horizontal, 14).frame(height: 30).background(DiscoboxAppearance.chrome)
                }
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(id: "workspace.sidebar", placement: .navigation) {
                        Button { commands.focusMode.toggle() } label: { Label("Toggle sidebar", systemImage: "sidebar.left") }
                            .help("Show or hide boxes")
                    }.studioPlainBackground()
                    ToolbarItem(id: "workspace.title", placement: .principal) {
                        Text([connections.active.profile.displayName, workspace.selection.selectedBox?.displayName].compactMap { $0 }.joined(separator: " › ").isEmpty ? "Discobox" : [connections.active.profile.displayName, workspace.selection.selectedBox?.displayName].compactMap { $0 }.joined(separator: " › "))
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    }.studioPlainBackground()
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible, placement: .automatic)
                    } else {
                        ToolbarItem(placement: .automatic) { Spacer() }
                    }
                    ToolbarItem(id: "workspace.actions", placement: .automatic) {
                        HStack(spacing: 12) {
                            let hidden = commands.currentLayout?.isSplit != true
                            Button { commands.performAppShortcut(.toggleShells) } label: {
                                let count = commands.currentLayout?.terminalIDs.count ?? 0
                                Label(count == 0 ? "New shell" : "Shells · \(count)", systemImage: "terminal")
                            }.labelStyle(.titleAndIcon).buttonStyle(.borderless).frame(width: 92)
                                .opacity(hidden ? 1 : 0).disabled(!hidden || workspace.selection.selectedBox?.isRunning != true && commands.currentLayout?.companionIDs.isEmpty != false)
                                .allowsHitTesting(hidden).accessibilityHidden(!hidden)
                                .accessibilityIdentifier("workspace.restoreShells")
                                .help("Show the last shell (" + commands.appShortcuts[.toggleShells] + ")")
                            WorkspaceDesktopButton()
                            Button { commands.toggleServices() } label: { Label("Services", systemImage: "network") }
                                .labelStyle(.titleAndIcon).buttonStyle(.borderless)
                                .foregroundStyle(commands.showInspector && commands.inspectorSection == "services" ? DiscoboxAppearance.accent : .primary)
                                .disabled(workspace.selection.selectedBox == nil).help("Show or hide services")
                                .accessibilityIdentifier("workspace.services")
                            Menu {
                                Button("Box Inspector") { commands.inspectorSection = "box"; commands.showInspector = true }
                                Button("Files") { commands.perform(.files) }.disabled(workspace.selection.selectedBox == nil)
                                Button("Tools & Additional Agent…") { commands.showTools = true }
                                Divider()
                                if let box = workspace.selection.selectedBox { BoxActionMenu(box: box) { choose($0, box: box) } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .disabled(workspace.selection.selectedBox == nil).help("Actions for this box")
                        }.font(.system(size: 12)).foregroundStyle(.primary).frame(width: 340, alignment: .trailing)

                    }.studioPlainBackground()
                }
                .toolbarBackground(DiscoboxAppearance.chrome, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .toolbar(removing: .sidebarToggle)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if workspace.connectionState.connectionError != nil {
                        ConnectionRecoveryBanner(workspace: workspace, computer: connections.active.profile.displayName) {
                            connections.disconnect(connections.activeID)
                        }
                    }
                    if let error = workspace.selection.commandError {
                        HStack { Notice(text: error, symbol: "exclamationmark.triangle"); Button("Dismiss") { workspace.selection.commandError = nil }.padding(.trailing) }
                    }
                }
            } else { WelcomeView() }
        }
        .background(WorkspaceWindowReader(commands: commands))
        .sheet(isPresented: $commands.showCommands) { CommandsSheet().environment(commands) }
        .background {
            // These dialogs belong to one computer. Only their presentation
            // anchor resets on a host change, not the shared sidebar.
            WorkspaceHostDialogs(showInbox: $showInbox).id(workspace.connectionState.connectionID)
        }
        .onChange(of: connections.activeID) { showInbox = false }
        .background { WorkspaceDialogs() }
        .sheet(isPresented: $showTagFilters) {
            TagFilterSheet(choices: tagChoices, selected: tagBinding, matchAny: matchAnyBinding)
        }
    }
    private var sidebar: some View {
                    VStack(spacing: 0) {
                        HStack {
                            Menu {
                                Picker("Filter", selection: filterBinding) {
                                    ForEach(BoxFilter.allCases) { Text($0.rawValue).tag($0) }
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
                            } label: { Text(currentFilter.rawValue).fontWeight(.semibold) }
                            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.primary)
                            Spacer()
                            Button { commands.newBox() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New box")
                            if refreshingBoxes { ProgressView().controlSize(.small) }
                            Text("\(connections.browserBoxes.count)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                        TextField("Find a box", text: searchBinding)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12)).padding(.horizontal, 14).padding(.bottom, 10)
                        if currentFilter != .archived {
                            let counts = activityCounts
                            BoxActivityFilters(selection: activityBinding, needsYou: counts.needsYou, working: counts.working)
                                .padding(.horizontal, 14).padding(.bottom, 10)
                        }
                        if !selectedTags.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 5) {
                                    Text(matchAnyTag ? "Any:" : "All:").font(.caption2).foregroundStyle(.secondary)
                                    ForEach(selectedTags.sorted(), id: \.self) { tag in
                                        Button { _ = connections.browser.selectedTags.remove(tag) } label: {
                                            HStack(spacing: 4) { Text(tag); Image(systemName: "xmark").font(.system(size: 8)) }
                                                .font(.caption).padding(.horizontal, 7).padding(.vertical, 4)
                                                .background(.quaternary, in: Capsule())
                                        }.buttonStyle(.plain).help("Remove filter: " + tag)
                                    }
                                }
                            }.padding(.horizontal, 10).padding(.bottom, 6)
                        }
                        ComputersSidebar(grouping: grouping, tagKey: groupingTagKey)
                            .frame(minHeight: 120)
                            .refreshable { await refreshBoxes() }
                            .background(BoxPullToRefresh { await refreshBoxes() })
                            .help("Pull down at the top to refresh, or press ⌘R.")
                            .accessibilityAction(named: Text("Refresh boxes")) { Task { await refreshBoxes() } }
                        if !commands.focusMode { HarnessUsageSection().layoutPriority(1) }
                    }.frame(minWidth: commands.focusMode ? 0 : 220,
                            idealWidth: commands.focusMode ? 0 : 282,
                            maxWidth: commands.focusMode ? 0 : 360)
                        .clipped().opacity(commands.focusMode ? 0 : 1)
                        .allowsHitTesting(!commands.focusMode)
                        .accessibilityHidden(commands.focusMode)
                        .accessibilityLabel("Boxes").background(DiscoboxAppearance.sidebar)
                        .background(GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in sidebarWidth = width; fitInspector() }
                        })
    }
    private func choose(_ action: BoxAction, box: Sandbox) {
        boxActions.present(action, box: box, on: workspace, connection: workspace.connectionState.connectionID)
    }
    private func fitInspector() {
        guard contentWidth > 0 else { return }
        let available = contentWidth - (commands.focusMode ? 0 : sidebarWidth)
        if let layout = commands.currentLayout, layout.shellsSplit, layout.shellSideBySide, available < 1140 {
            layout.shellSideBySide = false
        }
        let minimum: CGFloat = commands.currentLayout?.isSplit == true ? (commands.currentLayout?.shellsSplit == true && commands.currentLayout?.shellSideBySide == true ? 1080 : 720) : 360
        if commands.showInspector && available < minimum + 322 {
            responsiveRail = true
            commands.showInspector = false
        } else if commands.showInspector {
            responsiveRail = false
        }
    }
    private func refreshBoxes() async {
        guard !refreshingBoxes else { return }
        refreshingBoxes = true
        do {
            let workspaces = connections.sessions.filter { $0.connectionState.isConnected }
            await withTaskGroup(of: Void.self) { group in
                for target in workspaces { group.addTask { await target.refresh() } }
            }
        }
        refreshingBoxes = false
    }
}

private struct WorkspaceHostDialogs: View {
    @Environment(ConnectionSession.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    @Binding var showInbox: Bool
    var body: some View {
        @Bindable var commands = commands
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $showInbox) { ApprovalInboxView(boxID: nil).environment(workspace) }
            .sheet(isPresented: $commands.showTools) { ToolsSheet(box: workspace.selection.sandboxID).environment(workspace) }
            .sheet(isPresented: $commands.showApprovals) { ApprovalInboxView(boxID: nil).environment(workspace) }
    }
}

private struct WorkspaceDialogs: View {
    @Environment(ConnectionSession.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    var body: some View {
        @Bindable var commands = commands
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $commands.showCreateBox) { NewBoxSheet(repository: commands.creationSeed?.repository ?? "", computer: commands.creationSeed?.computer).environment(workspace) }
            .sheet(isPresented: $commands.choosingBox) { BoxChooser().environment(workspace) }
    }
}

struct BoxChooser: View {
    @Environment(WorkspaceCommands.self) private var commands: WorkspaceCommands?
    @Environment(ConnectionSession.self) private var workspace
    @Environment(Connections.self) private var connections: Connections
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var computerID = ""
    @State private var selected: BoxLocation?

    private struct StoppedSelection {
        let location: BoxLocation
        let intent: BoxStartIntent
        let session: ConnectionSession
    }
    @State private var stoppedSelection: StoppedSelection?

    private var results: [ConnectedBox] {
        connections.switcherBoxes.filter { (computerID.isEmpty || $0.location.connection == computerID) && $0.matches(query) }
    }
    private func group(_ item: ConnectedBox) -> BoxSwitcherGroup { BoxBrowser.switcherGroup(item) }

    var body: some View {
        SwiftUI.Group {
            if let stoppedSelection {
                BoxStartPrompt(intent: stoppedSelection.intent, cancel: { self.stoppedSelection = nil }, viewSaved: {
                    open(stoppedSelection.location, in: stoppedSelection.session, connection: stoppedSelection.intent.connection)
                }, open: {
                    open(stoppedSelection.location, in: stoppedSelection.session, connection: stoppedSelection.intent.connection)
                })
            } else { chooser }
        }.interactiveDismissDisabled(stoppedSelection?.intent.working == true)
    }

    @ViewBuilder private var chooser: some View {
        let matches = results
        let groups: [BoxSwitcherGroup] = Array(Set(matches.map { group($0) })).sorted { $0.precedes($1) }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                StudioDialogHeader(title: "Switch box", symbol: "square.grid.2x2", shortcut: commands?.appShortcuts[.switchBox])
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    BoxChooserSearch(text: $query, move: move, choose: choose, cancel: { dismiss() })
                        .frame(height: 22)
                }
                .padding(10).background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiscoboxAppearance.accent.opacity(0.7), lineWidth: 1))
                HStack {
                    Group {
                        StudioMenuPicker(title: "Computer scope", selection: $computerID, options:
                            [.init(id: "", title: "All computers")] + connections.sessions.filter { $0.connectionState.isConnected }.map { .init(id: $0.id, title: $0.profile.displayName) }, alignment: .left)
                            .frame(width: 200, height: 20)
                    }
                    Spacer()
                    Text("\(matches.count) \(matches.count == 1 ? "box" : "boxes")").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(20)
            Divider().overlay(DiscoboxAppearance.border)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.self) { section in
                            let items = matches.filter { group($0) == section }
                            HStack(spacing: 6) {
                                Text(section.title.uppercased()).tracking(0.8)
                                Text("\(items.count)").monospacedDigit()
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(section.rank == 0 ? Color.orange : Color.secondary)
                            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                            ForEach(items) { item in
                                Button { select(item.id) } label: {
                                    BoxChooserRow(item: item, selected: selected == item.id)
                                }.buttonStyle(.plain).focusable(false).id(item.id)
                                    .accessibilityAddTraits(selected == item.id ? .isSelected : [])
                            }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
                .overlay {
                    if matches.isEmpty {
                        ContentUnavailableView("No matching boxes", systemImage: "magnifyingglass", description: Text("Try another name, harness, repository, or computer."))
                    }
                }
                .onChange(of: selected) { _, id in if let id { reader.scrollTo(id) } }
            }
            Divider().overlay(DiscoboxAppearance.border)
            HStack(spacing: 6) {
                StudioKeycap(text: "↑")
                StudioKeycap(text: "↓")
                Text("Navigate").padding(.trailing, 12)
                StudioKeycap(text: "↵")
                Text(matches.first(where: { $0.id == selected }).map { BoxAction.start.isAvailable(for: $0.box) } == true ? "Open…" : "Open").padding(.trailing, 12)
                StudioKeycap(text: "esc")
                Text("Close")
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10).background(DiscoboxAppearance.chrome)
        }.frame(width: 560, height: 580).background(DiscoboxAppearance.surface).tint(DiscoboxAppearance.accent)
            .onChange(of: matches.map(\.id), initial: true) { _, ids in
                if selected == nil || !ids.contains(selected!) { selected = ids.first }
            }
            .onChange(of: connections.sessions.filter { $0.connectionState.isConnected }.map(\.id)) { _, ids in
                if !computerID.isEmpty && !ids.contains(computerID) { computerID = "" }
            }
    }
    private func move(_ delta: Int) {
        let matches = results
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selected } ?? 0
        selected = matches[min(max(index + delta, 0), matches.count - 1)].id
    }
    private func choose() {
        // Return can arrive before SwiftUI reconciles the highlighted row after
        // a query/scope edit. Resolve against the current results immediately.
        let matches = results
        if let item = matches.first(where: { $0.id == selected }) ?? matches.first { select(item.id) }
    }
    private func select(_ id: BoxLocation) {
        let target: ConnectionSession
        let computer: String
        guard let host = connections.session(id.connection), host.connectionState.isConnected else { return }
        target = host; computer = host.profile.displayName
        guard let box = target.inventory.sandboxes.first(where: { $0.id == id.box }) else { return }
        if BoxAction.start.isAvailable(for: box) {
            stoppedSelection = .init(location: id, intent: .init(connection: target.connectionState, inventory: target.inventory, pending: target.pending, commands: target.commands, box: box, computer: computer), session: target)
        } else { open(id, in: target, connection: target.connectionState.connectionID) }
    }
    private func open(_ id: BoxLocation, in target: ConnectionSession, connection: UUID) {
        guard target.connectionState.isConnected, target.connectionState.connectionID == connection else { return }
        commands?.choosingBox = false
        dismiss()
        Task {
            guard target.connectionState.isConnected, target.connectionState.connectionID == connection else { return }
            guard connections.session(id.connection) === target else { return }
            await connections.selectBox(id)
        }
    }
}

/// The switcher has no per-row sheets, approval buttons, or context menus.
private struct BoxChooserRow: View {
    let item: ConnectedBox
    let selected: Bool
    private var metadata: String {
        [item.box.harnessName == item.box.displayName ? nil : item.box.harnessName, item.box.repository, item.box.branch]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 10) {
            BoxStatusLight(indicator: .init(box: item.box, activity: item.activity ?? AgentActivity(box: item.box), power: item.power))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.box.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !metadata.isEmpty { Text(metadata).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 8)
            BoxMaintenanceIndicators(box: item.box)
            if !item.computer.isEmpty {
                Text(item.computer).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(DiscoboxAppearance.chrome, in: RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: 125, alignment: .trailing)
            }
            Image(systemName: "return").font(.system(size: 10)).foregroundStyle(DiscoboxAppearance.accent)
                .opacity(selected ? 1 : 0).frame(width: 14).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).frame(minHeight: 56)
        .background(selected ? DiscoboxAppearance.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? DiscoboxAppearance.accent.opacity(0.45) : .clear, lineWidth: 0.5))
        .contentShape(Rectangle())
        .accessibilityValue(["Box: " + item.power.label, item.activity.map { "Agent: " + $0.label }].compactMap { $0 }.joined(separator: ", "))
        .help(["Box: " + item.power.label, item.power.message, item.activity.map { "Agent: " + $0.label }, item.activity?.message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
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
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
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

struct RepositoryGroupHeader: View {
    let repository: String
    let count: Int
    let symbol: String
    let expanded: Bool
    var toggle: (() -> Void)? = nil
    var newBox: (() -> Void)? = nil
    private var parts: [String] { repository.split(separator: "/").map(String.init) }
    var body: some View {
        HStack(spacing: 4) {
            Button { toggle?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Image(systemName: symbol).foregroundStyle(.secondary)
                    if symbol == "folder" && parts.count > 1 {
                        (Text(parts.dropLast().joined(separator: "/") + " / ").foregroundColor(.secondary)
                         + Text(parts.last ?? repository).bold()).lineLimit(1).truncationMode(.middle)
                    } else { Text(repository).bold().lineLimit(1) }
                    Spacer(minLength: 2)
                    Text(String(count)).monospacedDigit().foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(repository)
                .accessibilityLabel("\(repository), \(count) boxes").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if let newBox {
                Button(action: newBox) { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 23) }
                    .buttonStyle(.plain).foregroundStyle(DiscoboxAppearance.accent)
                    .help("New box in " + repository).accessibilityLabel("New box in " + repository)
                    .accessibilityIdentifier("repository.newBox")
            }
        }.font(.system(size: 11)).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 6)
            .overlay(alignment: .top) { DiscoboxAppearance.border.opacity(0.7).frame(height: 1) }
    }
}

struct BoxRow: View {
    let box: Sandbox
    var computer: String? = nil
    /// Precomputed by the sidebar; without it the row derives from its workspace.
    var presentation: BoxRowPresentation? = nil
    @Environment(ConnectionSession.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(WorkspaceCommands.self) private var commands: WorkspaceCommands?
    @State private var showInbox = false
    var body: some View {
        let state = presentation ?? workspace.rowPresentation(for: box)
        let activity = state.activity, power = state.power
        let indicator = BoxIndicator(box: box, activity: activity, power: power)
        let tint = indicator.state == .error ? DiscoboxAppearance.activityFailure : DiscoboxAppearance.activityAttention
        HStack(alignment: .top, spacing: 9) {
            BoxStatusLight(indicator: indicator)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(state.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    if activity.approvalCount > 0 {
                        Button(activity.approvalCount == 1 ? "Review" : "Review \(activity.approvalCount)") { showInbox = true }
                            .buttonStyle(.borderless).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
                            .disabled(!state.canAct)
                            .accessibilityIdentifier("box.activity.review." + box.id)
                            .help("Review pending requests for this box")
                    } else if activity.needsYou || box.matchesAttention {
                        Button("Open", action: openAgent).buttonStyle(.borderless).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
                            .disabled(!state.canAct)
                            .accessibilityIdentifier("box.activity.open." + box.id)
                            .help("Open the agent on this box’s computer")
                    }
                    BoxMaintenanceIndicators(box: box)
                }
                HStack(spacing: 4) {
                    Text([box.harnessName ?? box.config.name ?? "Agent", computer].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                    Spacer(minLength: 4)
                    if state.isPending { ProgressView().controlSize(.mini) }
                    if let branch = box.branch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 90, alignment: .trailing)
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)

            }
        }.padding(.vertical, 8)
        .accessibilityValue([power.label, activity.label, box.needsRepair ? "Needs repair" : nil, box.upgradeAvailable ? "Upgrade available" : nil].compactMap { $0 }.joined(separator: ", "))
        .help([box.displayName, "Box: " + power.label, power.message, "Agent: " + activity.label, activity.message, box.repository, box.harnessName, box.branch, box.runtime.errorMessage, box.repairTooltip, box.upgradeTooltip].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .sheet(isPresented: $showInbox) { ApprovalInboxView(boxID: box.id).environment(workspace) }
    }
    private func openAgent() {
        let generation = workspace.connectionState.connectionID
        let host = connections?.sessions.first { $0 === workspace }
        Task {
            if let connections, let host {
                await connections.selectBox(.init(connection: host.id, box: box.id))
                guard connections.active === workspace else { return }
            } else { await workspace.selection.selectBox(box.id) }
            guard workspace.connectionState.connectionID == generation, workspace.selection.sandboxID == box.id else { return }
            commands?.install(workspace: workspace, connections: connections)
            commands?.perform(.agent)
        }
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
        case "running": DiscoboxAppearance.success
        case "failed", "error": DiscoboxAppearance.danger
        case "starting", "pending", "awaiting source", "stopping", "repairing": DiscoboxAppearance.warning
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
            .font(.caption).foregroundStyle(warning ? DiscoboxAppearance.warning : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(warning ? DiscoboxAppearance.warning.opacity(0.07) : Color.accentColor.opacity(0.05))
            .textSelection(.enabled)
    }
}

struct WelcomeView: View {
    @Environment(ConnectionSession.self) private var workspace
    @Environment(Connections.self) private var connections: Connections
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
            if workspace.connectionState.connectionError != nil {
                ConnectionRecoveryBanner(workspace: workspace, computer: connections.active.profile.displayName) {
                    connections.disconnect(connections.activeID)
                }.frame(maxWidth: 640)
            }
            HStack(spacing: 16) {
                Button("Explore demo workspace") {
                    Task {
                        await workspace.connect(client: DemoClient(), label: "Demo workspace", demo: true)
                        await workspace.selection.selectBox("demo-ui")
                    }
                }.buttonStyle(.link)
                if workspace.connectionState.isConnecting { Button("Cancel") { workspace.disconnect() } }
            }
            Text("Boxes stay available in your CLI and editor.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiscoboxAppearance.canvas)
    }
}

struct TagFilterSheet: View {
    let choices: [String]
    @Binding var selected: Set<String>
    @Binding var matchAny: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        StudioConfirmation(title: "Filter by tag", symbol: "tag") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Matching", selection: $matchAny) {
                    Text("Match all").tag(false)
                    Text("Match any").tag(true)
                }.pickerStyle(.segmented)
                StudioConfirmationField(title: "Search") { TextField("Find a tag", text: $search) }
                List(choices.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(get: { selected.contains(tag) }, set: { on in
                        if on { selected.insert(tag) } else { selected.remove(tag) }
                    })).toggleStyle(.checkbox)
                }.listStyle(.plain).scrollContentBackground(.hidden).studioCard()
            }
        } footer: {
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear filters") { selected.removeAll() }.disabled(selected.isEmpty)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.frame(height: 480)
    }
}
