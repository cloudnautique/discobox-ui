import SwiftUI
import DiscoboxCore

struct ComputersSidebar: View {
    @Environment(Connections.self) private var connections
    @Environment(ConnectionRuntimes.self) private var runtimes
    @Environment(Workspace.self) private var workspace
    let grouping: String
    let tagKey: String
    @State private var resourceHost: ConnectionSession?
    @State private var purge: SidebarPurgeRequest?
    @AppStorage("sidebarComputersExpanded") private var computersExpanded = true
    @AppStorage("collapsedComputerRepositoryGroups") private var collapsedData = "[]"
    private var browser: BoxBrowser { connections.browser }
    private var items: [ConnectedBox] { connections.browserBoxes }
    private var collapsed: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: Data(collapsedData.utf8))) ?? []) }
        nonmutating set { collapsedData = String(data: (try? JSONEncoder().encode(newValue.sorted())) ?? Data(), encoding: .utf8) ?? "[]" }
    }
    private func collapseKey(_ group: String) -> String { [browser.computerID ?? "all", grouping, tagKey, group].joined(separator: "\n") }
    private var selection: Binding<Set<BoxLocation>> {
        Binding(get: {
            browser.filter == .archived ? browser.archivedSelection : Set(workspace.sandboxID.map { [BoxLocation(connection: connections.activeID, box: $0)] } ?? [])
        }, set: { ids in
            // Ignore selection callbacks from the outgoing host's native List.
            guard connections.active.workspace === workspace else { return }
            if browser.filter == .archived { browser.selectArchives(ids) }
            else if let location = ids.first(where: { $0.box != workspace.sandboxID || $0.connection != connections.activeID }) ?? ids.first {
                Task { await connections.selectBox(location) }
            }
        })
    }
    private var selectedArchives: [ConnectedBox] { items.filter { browser.archivedSelection.contains($0.location) } }
    private var canPurge: Bool {
        !selectedArchives.isEmpty && Set(selectedArchives.map { $0.location.connection }).count == 1 && selectedArchives.allSatisfy { item in
            BoxAction.purge.isAvailable(for: item.box) && connections.session(item.location.connection)?.workspace.pendingBoxActions.contains(item.box.id) == false
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            computerSection
            List(selection: selection) {
                if grouping == "none" {
                    ForEach(items) { item in row(item) }
                } else {
                    let groups = Dictionary(grouping: items) { BoxOrganization.group($0.box, by: grouping, tagKey: tagKey) }
                    ForEach(groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { group in
                        let key = collapseKey(group)
                        Button {
                            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
                        } label: {
                            RepositoryGroupHeader(repository: group, count: groups[group]?.count ?? 0,
                                symbol: grouping == "repository" ? "folder" : grouping == "harness" ? "terminal" : grouping == "tag" ? "tag" : "circle",
                                expanded: !collapsed.contains(key))
                        }.buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 5, trailing: 0))
                            .listRowSeparator(.hidden)
                        if !collapsed.contains(key) { ForEach(groups[group] ?? []) { item in row(item) } }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .overlay { if items.isEmpty { emptyState } }
                .onDeleteCommand { confirmPurge() }
            if browser.filter == .archived { archiveActions }
        }
        .background(DiscoboxAppearance.sidebar)
        .sheet(item: $resourceHost) { host in
            PoolResourcesView(computer: host.profile.displayName)
                .environment(host.workspace)
                .environment(runtimes.runtime(host.id).terminals)
                .environment(runtimes.runtime(host.id).forwards)
                .environment(runtimes.runtime(host.id).desktops)
        }
        .sheet(item: $purge) { target in
            BulkPurgeSheet(request: target.request) { purged in
                browser.archivedSelection = Set(browser.archivedSelection.filter { $0.connection != target.host.id || !purged.contains($0.box) })
            }.environment(target.host.workspace)
        }
        .onChange(of: browser.archivedSelection) { _, ids in
            guard browser.filter == .archived, ids.count == 1, let location = ids.first else { return }
            Task { await connections.selectBox(location) }
        }
        .onChange(of: items.map(\.location)) { _, visible in browser.archivedSelection.formIntersection(Set(visible)) }
        .onChange(of: browser.filter) { browser.archivedSelection.removeAll() }
    }
    private var computerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { computersExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: computersExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("Computers").font(.system(size: 11, weight: .semibold))
                    if !computersExpanded {
                        Text(browser.computerID.flatMap { connections.session($0)?.profile.displayName } ?? "All")
                            .font(.caption2).lineLimit(1)
                    }
                    Spacer()
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 6)
            if computersExpanded {
                Button { browser.computerID = nil; browser.archivedSelection.removeAll() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up").frame(width: 16).foregroundStyle(.secondary)
                        Text("All computers").fontWeight(browser.computerID == nil ? .semibold : .regular)
                        Spacer()
                        if browser.computerID == nil { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                    }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("computers.all")
                ForEach(connections.sessions) { host in
                    HStack(spacing: 6) {
                        Button { browser.toggleComputer(host.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: host.profile.endpoint.hasPrefix("unix:") ? "desktopcomputer" : "laptopcomputer").frame(width: 16).foregroundStyle(.secondary)
                                Text(host.profile.displayName).lineLimit(1)
                                Spacer(minLength: 0)
                                if !host.workspace.approvals.isEmpty { Text("\(host.workspace.approvals.count)").font(.caption2).foregroundStyle(.orange) }
                                Circle().fill(host.workspace.connectionError != nil ? .orange : host.workspace.isConnected ? .green : .secondary.opacity(0.5)).frame(width: 5, height: 5)
                            }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Filter boxes on " + host.profile.displayName + ". Click again to show all computers.")
                            .accessibilityIdentifier("computers.filter." + host.id)
                            .accessibilityAddTraits(browser.computerID == host.id ? .isSelected : [])
                        ComputerResourceButton(workspace: host.workspace) { resourceHost = host }
                            .disabled(!host.workspace.isConnected).padding(.trailing, 6)
                    }.background(browser.computerID == host.id ? DiscoboxAppearance.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contextMenu {
                            Button("Show All Computers") { browser.computerID = nil }
                            Button("Show Workspace") { connections.activate(host.id) }
                            Button("Manage Resources…") { resourceHost = host }.disabled(!host.workspace.isConnected)
                            if host.workspace.isConnected || host.workspace.isConnecting {
                                Button("Disconnect") { connections.disconnect(host.id) }
                            } else { Button("Connect") { connect(host) } }
                        }
                }
            }
        }.padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 7)
    }
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No matching boxes").font(.callout).foregroundStyle(.secondary)
            if browser.computerID != nil {
                Button("Show all computers") { browser.computerID = nil }.font(.caption)
            }
            if let host = connections.sessions.first(where: { $0.id == browser.computerID }), !host.workspace.isConnected {
                Button(host.workspace.isConnecting ? "Connecting…" : "Connect to " + host.profile.displayName) { connect(host) }.disabled(host.workspace.isConnecting)
                if let error = host.workspace.connectionError { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        }.padding(16)
    }
    private var archiveActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("\(browser.archivedSelection.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { selectAllArchives() }.buttonStyle(.borderless).font(.caption).disabled(items.isEmpty)
                    .help("Select archived boxes on one computer at a time.")
            }
            Button("Purge Selected…", systemImage: "trash", role: .destructive) { confirmPurge() }.disabled(!canPurge)
            Text("Bulk purge applies to one computer at a time.").font(.caption2).foregroundStyle(.secondary)
        }.padding(10)
    }
    private func selectAllArchives() {
        let preferred = browser.computerID ?? browser.archivedSelection.first?.connection ?? connections.activeID
        let target = items.contains { $0.location.connection == preferred } ? preferred : items.first?.location.connection
        browser.selectArchives(Set(items.filter { $0.location.connection == target }.map(\.location)))
    }
    private func confirmPurge() {
        guard canPurge, let first = selectedArchives.first, let host = connections.session(first.location.connection) else { return }
        purge = .init(host: host, request: .init(boxes: selectedArchives.map(\.box), connection: host.workspace.connectionID))
    }
    private func row(_ item: ConnectedBox) -> some View {
        Group {
            if let host = connections.session(item.location.connection) {
                ComputerBoxRow(box: item.box, host: host, showComputer: browser.computerID == nil)
                    .environment(host.workspace)
                    .environment(runtimes.runtime(host.id).terminals)
                    .environment(runtimes.runtime(host.id).forwards)
                    .environment(runtimes.runtime(host.id).desktops)
            }
        }.tag(item.location).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7))
    }
    private func connect(_ host: ConnectionSession) {
        Task { do { _ = try await connections.connect(host.profile) { try ConnectionClients.make(host.profile) } }
            catch { host.workspace.commandError = error.localizedDescription } }
    }
}

private struct SidebarPurgeRequest: Identifiable {
    let id = UUID()
    let host: ConnectionSession
    let request: BulkPurgeRequest
}

private struct ComputerResourceButton: View {
    let workspace: Workspace
    let open: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let warning = workspace.resources.pools.contains { pool in
                let health = workspace.resources.health(pool.id, now: context.date)
                return health.level == .warning || health.level == .blocked
            }
            Button(action: open) {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                    .foregroundStyle(warning ? Color.orange : Color.secondary)
            }.buttonStyle(.borderless)
                .help(warning ? "Pool resource warning — Manage Resources" : "Manage pool resources and caches")
                .accessibilityLabel("Manage Resources")
                .accessibilityIdentifier("computer.resources")
        }
    }
}

private struct ComputerBoxRow: View {
    let box: Sandbox
    let host: ConnectionSession
    let showComputer: Bool
    @Environment(Connections.self) private var connections
    @State private var action: BoxActionRequest?
    var body: some View {
        BoxRow(box: box, computer: showComputer ? host.profile.displayName : nil)
            .contextMenu {
                Button("Open Workspace") { Task { await connections.selectBox(.init(connection: host.id, box: box.id)) } }
                Button("Open Shell") {
                    let generation = host.workspace.connectionID
                    Task {
                        await connections.selectBox(.init(connection: host.id, box: box.id))
                        if host.workspace.connectionID == generation, host.workspace.sandboxID == box.id { await host.workspace.openShell() }
                    }
                }.disabled(!box.isRunning)
                Divider()
                BoxActionMenu(box: box) { action = .init(box: box, action: $0, connection: host.workspace.connectionID) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if BoxAction.archive.isAvailable(for: box) { Button { action = .init(box: box, action: .archive, connection: host.workspace.connectionID) } label: { Label("Archive", systemImage: "archivebox") }.tint(.orange) }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                let power: BoxAction = box.isRunning ? .stop : .start
                if power.isAvailable(for: box) { Button { action = .init(box: box, action: power, connection: host.workspace.connectionID) } label: { Label(power.title, systemImage: power.symbol) }.tint(box.isRunning ? .orange : .green) }
            }
            .sheet(item: $action) { BoxActionSheet(request: $0).environment(host.workspace) }
    }
}
