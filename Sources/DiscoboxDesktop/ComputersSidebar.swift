import SwiftUI
import DiscoboxCore

struct ComputersSidebar: View {
    @Environment(Connections.self) private var connections
    @Environment(ConnectionRuntimes.self) private var runtimes
    @Environment(Workspace.self) private var workspace
    let grouping: String
    let tagKey: String
    let tags: Set<String>
    let matchAnyTag: Bool
    @AppStorage("collapsedComputerGroups") private var collapsedData = "[]"
    @AppStorage("collapsedComputerRepositoryGroups") private var collapsedRepositoryData = "[]"
    private var collapsedRepositories: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: Data(collapsedRepositoryData.utf8))) ?? []) }
        nonmutating set { collapsedRepositoryData = String(data: (try? JSONEncoder().encode(newValue.sorted())) ?? Data(), encoding: .utf8) ?? "[]" }
    }
    private var collapsed: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: Data(collapsedData.utf8))) ?? []) }
        nonmutating set { collapsedData = String(data: (try? JSONEncoder().encode(newValue.sorted())) ?? Data(), encoding: .utf8) ?? "[]" }
    }
    private var selection: Binding<BoxLocation?> {
        Binding(get: { workspace.sandboxID.map { BoxLocation(connection: connections.activeID, box: $0) } }, set: { location in
            // An outgoing List can publish its old selection while the root
            // changes computers. It must not navigate back to the old host.
            guard connections.active.workspace === workspace else { return }
            if let location {
                Task {
                    guard connections.active.workspace === workspace else { return }
                    await connections.selectBox(location)
                }
            }
        })
    }
    private func boxes(_ host: ConnectionSession) -> [Sandbox] {
        let waiting = Set(host.workspace.approvals.map(\.boxID))
        return host.workspace.sandboxes.filter { box in
            let include: Bool
            switch workspace.filter {
            case .all: include = !box.isArchived
            case .running: include = box.isRunning
            case .attention: include = box.matchesAttention || waiting.contains(box.id)
            case .archived: include = box.isArchived
            }
            return include && workspace.searchText.split(whereSeparator: { $0.isWhitespace }).allSatisfy { host.profile.displayName.localizedCaseInsensitiveContains($0) || box.matchesSearch(String($0)) } && BoxOrganization.matches(tags: box.meta?.tags ?? [:], selectors: tags, matchAny: matchAnyTag)
        }.sorted {
            func rank(_ box: Sandbox) -> Int { waiting.contains(box.id) || box.matchesAttention ? 0 : box.isRunning ? 1 : 2 }
            return rank($0) == rank($1) ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending : rank($0) < rank($1)
        }
    }
    var body: some View {
        List(selection: selection) {
            ForEach(connections.sessions) { host in
                let items = boxes(host)
                HStack(spacing: 6) {
                    Button {
                        if collapsed.contains(host.id) { collapsed.remove(host.id) } else { collapsed.insert(host.id) }
                    } label: { Image(systemName: collapsed.contains(host.id) ? "chevron.right" : "chevron.down").font(.caption2).frame(width: 12) }.buttonStyle(.plain)
                    Button { connections.activate(host.id) } label: {
                        HStack {
                            Text(host.profile.displayName).font(.headline).lineLimit(1)
                            Spacer(minLength: 0)
                            if !host.workspace.approvals.isEmpty { Text("\(host.workspace.approvals.count) !").foregroundStyle(.red).font(.caption.weight(.bold)) }
                            Circle().fill(host.workspace.connectionError != nil ? .orange : host.workspace.isConnected ? .green : .secondary.opacity(0.5)).frame(width: 6, height: 6)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(.vertical, 7)
                    .contextMenu {
                        Button("Show Boxes") { connections.activate(host.id) }
                        if host.workspace.isConnected || host.workspace.isConnecting {
                            Button("Disconnect") { connections.disconnect(host.id) }
                        } else { Button("Connect") { connect(host) } }
                    }
                if !collapsed.contains(host.id) {
                    if !host.workspace.isConnected {
                        Button(host.workspace.isConnecting ? "Connecting…" : "Connect…") { connect(host) }
                            .disabled(host.workspace.isConnecting).font(.callout)
                        if let error = host.workspace.connectionError ?? host.workspace.commandError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3) }
                    } else if grouping == "none" {
                        ForEach(items) { box in row(box, host: host) }
                    } else {
                        let groups = Dictionary(grouping: items) { BoxOrganization.group($0, by: grouping, tagKey: tagKey) }
                        ForEach(groups.keys.sorted(), id: \.self) { group in
                            let key = [host.id, grouping, tagKey, group].joined(separator: "\n")
                            Button {
                                if collapsedRepositories.contains(key) { collapsedRepositories.remove(key) } else { collapsedRepositories.insert(key) }
                            } label: {
                                RepositoryGroupHeader(repository: group, count: groups[group]?.count ?? 0,
                                    symbol: grouping == "repository" ? "folder" : grouping == "harness" ? "terminal" : grouping == "tag" ? "tag" : "circle",
                                    expanded: !collapsedRepositories.contains(key))
                            }.buttonStyle(.plain).padding(.top, 4)
                            if !collapsedRepositories.contains(key) { ForEach(groups[group] ?? []) { box in row(box, host: host) } }
                        }
                    }
                }
            }
        }.listStyle(.sidebar)
    }
    private func row(_ box: Sandbox, host: ConnectionSession) -> some View {
        ComputerBoxRow(box: box, host: host)
            .environment(host.workspace)
            .environment(runtimes.runtime(host.id).terminals)
            .environment(runtimes.runtime(host.id).forwards)
            .environment(runtimes.runtime(host.id).desktops)
            .tag(BoxLocation(connection: host.id, box: box.id))
    }
    private func connect(_ host: ConnectionSession) {
        Task { do { _ = try await connections.connect(host.profile) { try ConnectionClients.make(host.profile) } }
            catch { host.workspace.commandError = error.localizedDescription } }
    }
}

private struct ComputerBoxRow: View {
    let box: Sandbox
    let host: ConnectionSession
    @Environment(Connections.self) private var connections
    @State private var action: BoxActionRequest?
    var body: some View {
        BoxRow(box: box)
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
