import SwiftUI
import AppKit
import DiscoboxCore

struct BoxWorkspaceView: View {
    let box: Sandbox
    @Environment(Workspace.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    @Environment(TerminalStore.self) private var terminals
    @State private var showInbox = false
    @State private var closing: Exec?
    private var harness: Exec? { workspace.execs.first(where: { $0.primary == true }) ?? workspace.execs.first(where: { !$0.isShell }) }
    private var companions: [Exec] { workspace.execs.filter { $0.id != harness?.id } }
    private var layout: WorkspaceTabs { commands.layout(for: workspace.connectionID.uuidString + box.id) }

    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.detailError { Notice(text: error, symbol: "exclamationmark.triangle") }
            // Keep the tab's container stable when hiding the pinned agent;
            // reparenting a retained NSView across two outgoing/incoming SwiftUI
            // branches can let the outgoing branch reclaim the terminal.
            if layout.sideBySide { HSplitView { panes } }
            else { VSplitView { panes } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
        .onChange(of: workspace.execs.map(\.id), initial: true) { _, ids in
            // selectBox clears inventory before its async refresh. That empty
            // transition must not discard the box's remembered tab selection.
            if workspace.sandboxID == box.id, !workspace.execs.isEmpty, ids == workspace.execs.map(\.id) { layout.reconcile(companions.map { "exec:" + $0.id }) }
        }
        .onChange(of: workspace.execID) { old, id in
            guard workspace.sandboxID == box.id, old != nil, let id else { return }
            if companions.contains(where: { $0.id == id }) { layout.open("exec:" + id) }
        }
        .onChange(of: layout.selected) { _, id in
            if workspace.sandboxID == box.id, id.hasPrefix("exec:") {
                let exec = String(id.dropFirst(5))
                if workspace.execID != exec { Task { if workspace.sandboxID == box.id { await workspace.selectExec(exec) } } }
            }
        }
        .onChange(of: commands.showInspector) { _, visible in
            guard !visible else { return }
            let exec = layout.agentFocused || layout.selected == "agent" ? harness?.id : (layout.selected.hasPrefix("exec:") ? String(layout.selected.dropFirst(5)) : nil)
            guard let exec else { return }
            let identity = TerminalIdentity(connection: workspace.connectionID, endpoint: workspace.transportEndpoint,
                                            project: workspace.projectID ?? "", box: box.id, exec: exec, demo: workspace.isDemo)
            terminals.focus(identity)
        }
        .onChange(of: commands.showFiles) { _, show in if show { layout.open("files") } }
        .onChange(of: commands.showAudit) { _, show in if show { layout.open("audit") } }

        .sheet(isPresented: $showInbox) { ApprovalInboxView(boxID: box.id).environment(workspace) }
        .confirmationDialog("Close this terminal and end its running process?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            if let closing {
                Button("Close Terminal", role: .destructive) {
                    let identity = TerminalIdentity(connection: workspace.connectionID, endpoint: workspace.transportEndpoint, project: workspace.projectID ?? "", box: box.id, exec: closing.id, demo: workspace.isDemo)
                    Task {
                        do { try await workspace.closeShell(closing.id); terminals.reconnect(identity) }
                        catch { workspace.commandError = error.localizedDescription }
                    }
                    self.closing = nil
                }
            }
        }
    }

    @ViewBuilder private var panes: some View {
        if layout.keepAgent || layout.selected == "agent" { agentPane }
        if layout.selected != "agent" { selectedPane }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(layout.keepAgent ? layout.ids.filter { $0 != "agent" } : layout.ids, id: \.self) { id in
                            HStack(spacing: 6) {
                                Button { layout.open(id) } label: {
                                    Label(title(id), systemImage: symbol(id)).lineLimit(1)
                                }.buttonStyle(.plain)
                                if id != "agent" {
                                    Button { close(id) } label: { Image(systemName: "xmark").font(.caption2) }
                                        .buttonStyle(.plain).help("Close \(title(id))")
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(layout.selected == id ? DiscoboxAppearance.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(layout.selected == id ? DiscoboxAppearance.accent.opacity(0.3) : .clear, lineWidth: 1) }
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(layout.selected == id ? .isSelected : [])
                            .id(id)
                            .contextMenu {
                                Button("Select Tab") { layout.open(id) }
                                if id != "agent" {
                                    Button("Split Below Agent") { layout.sideBySide = false; layout.keepAgent = true; layout.open(id) }
                                    Button("Split Beside Agent") { layout.sideBySide = true; layout.keepAgent = true; layout.open(id) }
                                    Button("Show Tab Only") { layout.keepAgent = false; layout.open(id) }
                                    Divider()
                                    Button("Close Tab") { close(id) }
                                }
                            }
                        }
                    }
                }
                .onChange(of: layout.selected) { _, id in reader.scrollTo(id) }
            }
            tabControls
            if !layout.keepAgent { maximizeAgentButton }
        }.workspacePaneHeader()
    }
    private var maximizeAgentButton: some View {
        Button { commands.perform(.focus) } label: {
            Image(systemName: commands.isAgentMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .help(commands.isAgentMaximized ? "Restore workspace layout" : "Maximize agent")
        .accessibilityLabel(commands.isAgentMaximized ? "Restore workspace layout" : "Maximize agent")
    }
    private var tabControls: some View {
        @Bindable var layout = layout
        return HStack(spacing: 8) {
            if workspace.isOpeningShell { ProgressView().controlSize(.small) }
            Menu {
                Button("New Shell") { commands.perform(.newShell) }.disabled(!box.isRunning || workspace.isOpeningShell)
                Divider()
                Button("Audit") { layout.open("audit") }
                Button("Services") { commands.openServices() }
                Button("Files") { layout.open("files") }
                Button("Changes") { commands.perform(.changes) }.disabled(!box.isRunning)
                Button("Tools & Additional Agent…") { commands.showTools = true }
            } label: { Image(systemName: "plus") }.help("Open Tab")
            Menu {
                Toggle("Keep Agent Visible", isOn: $layout.keepAgent)
                Divider()
                Picker("Split Arrangement", selection: $layout.sideBySide) {
                    Text("Below Agent").tag(false)
                    Text("Beside Agent").tag(true)
                }.pickerStyle(.inline)
            } label: { Image(systemName: layout.sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2") }.help("Workspace Layout")
        }
    }
    private var agentPane: some View {
        VStack(spacing: 0) {
            if layout.keepAgent {
            HStack {
                Label("Agent", systemImage: "sparkles")
                if workspace.approvals.contains(where: { $0.boxID == box.id }) {
                    Button { showInbox = true } label: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                        .help("Review credential requests").accessibilityLabel("Review credential requests")
                }
                Spacer()
                if !layout.isSplit { tabControls }
                maximizeAgentButton
            }.workspacePaneHeader()
                .overlay(alignment: .bottom) { if layout.agentFocused { DiscoboxAppearance.accent.frame(height: 2) } }
                .onTapGesture { layout.agentFocused = true }
            } else {
                tabBar
                    .overlay(alignment: .bottom) { DiscoboxAppearance.accent.frame(height: 2) }
            }
            if let harness {
                ConsoleView(terminal: harness, focused: layout.agentFocused || !layout.isSplit, onFocus: { layout.agentFocused = true })
            } else { ContentUnavailableView("No harness terminal", systemImage: "terminal") }
        }.frame(minWidth: 280, minHeight: 180, maxHeight: .infinity)
    }
    private var selectedPane: some View {
        VStack(spacing: 0) {
            tabBar
                .overlay(alignment: .bottom) { if !layout.agentFocused { DiscoboxAppearance.accent.frame(height: 2) } }
                .onTapGesture { layout.agentFocused = false }
            Group {
                if let terminal = companions.first(where: { "exec:" + $0.id == layout.selected }) {
                    ConsoleView(terminal: terminal, focused: !layout.agentFocused || !layout.isSplit, onFocus: { layout.agentFocused = false })
                } else if layout.selected == "audit" { AuditView(boxID: box.id, focusSearch: !layout.agentFocused) }
                else if layout.selected == "services" { ServicesView(box: box) }
                else if layout.selected == "files" { FilesView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ToolPaneFocus(active: !layout.agentFocused && layout.selected != "audit" && !layout.selected.hasPrefix("exec:")))
            .simultaneousGesture(TapGesture().onEnded { layout.agentFocused = false })
        }.frame(minWidth: 280, minHeight: 180, maxHeight: .infinity)
    }
    private func title(_ id: String) -> String {
        switch id {
        case "agent": "Agent"
        case "audit": "Audit"
        case "services": "Services"
        case "files": "Files"
        default: companions.first(where: { "exec:" + $0.id == id })?.title ?? "Terminal"
        }
    }
    private func symbol(_ id: String) -> String {
        switch id {
        case "agent": "sparkles"
        case "audit": "list.bullet.rectangle"
        case "services": "network"
        case "files": "folder"
        default: "terminal"
        }
    }
    private func close(_ id: String) {
        if let exec = companions.first(where: { "exec:" + $0.id == id }) { closing = exec }
        else { layout.close(id) }
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
        self.font(.callout).buttonStyle(.borderless)
            .padding(.horizontal, 10).frame(height: 42).background(.bar)
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
                Notice(text: "Saved terminal state · Read only", symbol: "clock", warning: false)
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
