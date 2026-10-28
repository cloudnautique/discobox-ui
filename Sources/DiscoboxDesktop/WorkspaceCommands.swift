import SwiftUI
import AppKit
import DiscoboxCore

@MainActor @Observable final class WorkspaceCommands {
    var bindings: CommandBindings
    var appShortcuts: AppShortcuts
    var showTools = false
    var showFiles = false
    var showApprovals = false
    var showAudit = false
    var tab = WorkspaceTab.terminal
    var showInspector = false
    var inspectorSection = UserDefaults.standard.string(forKey: "inspectorSection") ?? "services" {
        didSet { UserDefaults.standard.set(inspectorSection, forKey: "inspectorSection") }
    }
    func openServices() { inspectorSection = "services"; showInspector = true }
    func toggleInspector() { showInspector.toggle() }

    var focusMode = false
    private struct AgentFocusSnapshot {
        let layout: WorkspaceTabs
        let selected: String
        let agentFocused: Bool
        let inspectorVisible: Bool
    }
    private var agentFocusSnapshot: AgentFocusSnapshot?
    var isAgentMaximized: Bool { agentFocusSnapshot?.layout === currentLayout && agentFocusSnapshot != nil }
    func restoreAgentLayout() {
        guard let saved = agentFocusSnapshot else { return }
        agentFocusSnapshot = nil
        saved.layout.open(saved.layout.ids.contains(saved.selected) ? saved.selected : "agent")
        saved.layout.agentFocused = saved.agentFocused
        showInspector = saved.inspectorVisible
    }
    private func toggleAgentMaximization() {
        if agentFocusSnapshot != nil { restoreAgentLayout(); return }
        guard let layout = currentLayout else { return }
        agentFocusSnapshot = AgentFocusSnapshot(layout: layout, selected: layout.selected,
            agentFocused: layout.agentFocused, inspectorVisible: showInspector)
        layout.open("agent")
        showInspector = false
    }
    var showCommands = false
    var showCreateBox = false
    var choosingBox = false
    var hint: String?
    private var layouts: [String: WorkspaceTabs] = [:]
    func layout(for key: String) -> WorkspaceTabs {
        if let layout = layouts[key] { return layout }
        let layout = WorkspaceTabs()
        layouts[key] = layout
        return layout
    }
    var currentLayout: WorkspaceTabs? {
        guard let workspace, let box = workspace.sandboxID else { return nil }
        return layout(for: workspace.connectionID.uuidString + box)
    }
    func resetLayouts() { restoreAgentLayout(); layouts.removeAll(); cancelPrefix() }
    func moveTab(_ delta: Int) { cancelPrefix(); currentLayout?.moveTab(delta) }
    func movePane() { cancelPrefix(); currentLayout?.movePane() }

    weak var window: NSWindow?
    private var workspace: Workspace?
    private var router = LeaderRouter()
    private var monitor: Any?
    private var timeout: Task<Void, Never>?
    private var swallowed: Set<UInt16> = []
    private let defaults: UserDefaults
    enum WorkspaceTab { case terminal, services }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "commandBindings.v1").flatMap { try? JSONDecoder().decode(CommandBindings.self, from: $0) }
        bindings = saved?.validationError == nil ? (saved ?? CommandBindings()) : CommandBindings()
        let shortcuts = defaults.data(forKey: "appShortcuts.v1").flatMap { try? JSONDecoder().decode(AppShortcuts.self, from: $0) }
        appShortcuts = shortcuts?.validationError == nil ? (shortcuts ?? AppShortcuts()) : AppShortcuts()
    }
    func save(_ value: CommandBindings) {
        guard value.validationError == nil else { return }
        cancelPrefix(); bindings = value
        defaults.set(try? JSONEncoder().encode(value), forKey: "commandBindings.v1")
    }
    func saveAppShortcuts(_ shortcuts: AppShortcuts) {
        guard shortcuts.validationError == nil else { return }
        appShortcuts = shortcuts
        defaults.set(try? JSONEncoder().encode(shortcuts), forKey: "appShortcuts.v1")
    }
    func keyboardShortcut(_ action: AppShortcutAction) -> KeyboardShortcut? {
        guard let shortcut = AppShortcut(appShortcuts[action]), let key = shortcut.key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: shortcut.swiftUIModifiers)
    }
    func performAppShortcut(_ action: AppShortcutAction) {
        guard workspace?.isConnected == true, window?.attachedSheet == nil else { return }
        cancelPrefix()
        switch action {
        case .newBox: showCreateBox = true
        case .switchBox: choosingBox = true
        case .previousTab: moveTab(-1)
        case .nextTab: moveTab(1)
        case .previousPane, .nextPane: movePane()
        case .toggleInspector: toggleInspector()
        case .help: showCommands = true
        }
    }
    func install(workspace: Workspace) {
        self.workspace = workspace
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { guard let self else { return false }; return self.route(event) == nil }
            return consumed ? nil : event
        }
    }
    func cancelPrefix() { router.cancel(); timeout?.cancel(); hint = nil }
    private func route(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp, swallowed.remove(event.keyCode) != nil { return nil }
        guard let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, workspace?.isConnected == true else { cancelPrefix(); return event }
        if event.type == .leftMouseDown { cancelPrefix(); return event }
        guard event.type == .keyDown else { return event }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let character = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
        for action in AppShortcutAction.allCases {
            guard let shortcut = AppShortcut(appShortcuts[action]) else { continue }
            if flags == shortcut.appKitModifiers && character == shortcut.key {
                swallowed.insert(event.keyCode)
                performAppShortcut(action)
                return nil
            }
        }
        guard !(window.firstResponder is NSTextView) else { return event }
        let token = Self.token(event)
        if event.isARepeat, swallowed.contains(event.keyCode) { return nil }
        let result = router.key(token, bindings: bindings)
        if result == .pass { return event }
        swallowed.insert(event.keyCode)
        timeout?.cancel()
        switch result {
        case .pending:
            hint = ([bindings.leader] + (router.sequence ?? [])).joined(separator: "  ") + "  …   Esc to cancel"
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.cancelPrefix()
            }
        case .literal(let text):
            hint = nil
            (window.firstResponder as? GhosttyTerminalView)?.sendLiteral(text)
        case .command(let command): hint = nil; perform(command)
        case .terminal(let number):
            hint = nil
            if let workspace, workspace.execs.indices.contains(number) {
                let terminal = workspace.execs[number]
                currentLayout?.open(terminal.primary == true ? "agent" : "exec:" + terminal.id)
                tab = .terminal; Task { await workspace.selectExec(terminal.id) }
            } else { message("No terminal \(number)") }
        case .unknown: message("No command for that sequence · \(bindings.leader) ? shows commands")
        default: hint = nil
        }
        return nil
    }
    static func token(_ event: NSEvent) -> String {
        let special: [UInt16:String] = [53:"escape",123:"left",124:"right",125:"down",126:"up",36:"enter",48:"tab",49:"space"]
        if let name = special[event.keyCode] { return name }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if flags == .control { return "ctrl+" + (event.characters(byApplyingModifiers: []) ?? "").lowercased() }
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) { return "unsupported" }
        return event.characters ?? ""
    }
    func perform(_ command: WorkspaceCommand) {
        guard let workspace else { return }
        switch command {
        case .tools: showTools = true
        case .changes: Task { do { try await workspace.openSession(tool: "ai.discobox.diff") } catch { workspace.commandError = error.localizedDescription } }
        case .files: showFiles = true; currentLayout?.open("files")
        case .approvals: showApprovals = true
        case .agent:
            if let layout = currentLayout, layout.isSplit { layout.agentFocused = true }
            else { currentLayout?.open("agent") }
            tab = .terminal
            if let exec = (workspace.execs.first(where: { $0.primary == true }) ?? workspace.execs.first) { Task { await workspace.selectExec(exec.id) } }
        case .previousTerminal: moveTerminal(-1)
        case .nextTerminal: moveTerminal(1)
        case .newShell: tab = .terminal; Task { await workspace.openShell() }
        case .services: openServices()
        case .audit: showFiles = false; showAudit = true; currentLayout?.open("audit")
        case .boxes: focusMode = false; choosingBox = true
        case .previousBox: moveBox(-1)
        case .nextBox: moveBox(1)
        case .focus:
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { toggleAgentMaximization() }
        case .refresh: Task { await workspace.refresh() }
        case .help: showCommands = true
        case .disconnect: workspace.disconnect()
        }
    }
    private func moveTerminal(_ delta: Int) {
        guard let workspace, !workspace.execs.isEmpty else { return }
        let index = workspace.execs.firstIndex { $0.id == workspace.execID } ?? 0
        tab = .terminal
        let terminal = workspace.execs[(index + delta + workspace.execs.count) % workspace.execs.count]
        currentLayout?.open(terminal.primary == true ? "agent" : "exec:" + terminal.id)
        Task { await workspace.selectExec(terminal.id) }
    }
    private func moveBox(_ delta: Int) {
        guard let workspace, !workspace.visibleBoxes.isEmpty else { return }
        let boxes = workspace.visibleBoxes
        let index = boxes.firstIndex { $0.id == workspace.sandboxID } ?? 0
        tab = .terminal
        Task { await workspace.selectBox(boxes[(index + delta + boxes.count) % boxes.count].id) }
    }
    private func message(_ text: String) {
        hint = text
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.hint = nil
        }
    }
}

struct WorkspaceWindowReader: NSViewRepresentable {
    let commands: WorkspaceCommands
    func makeNSView(context: Context) -> NSView { Probe(commands: commands) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Probe: NSView {
        let commands: WorkspaceCommands
        init(commands: WorkspaceCommands) { self.commands = commands; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Terminal grids and sidebar controls must occupy the content area,
            // never the unified titlebar's full-size-content extension.
            if let window, window.styleMask.contains(.fullSizeContentView) {
                let frame = window.frame
                window.styleMask.remove(.fullSizeContentView)
                window.setFrame(frame, display: false)
            }
            commands.window = window
        }
    }
}

struct KeybindingSettings: View {
    @Environment(WorkspaceCommands.self) private var commands
    @State private var draft = CommandBindings()
    @State private var shortcutDraft = AppShortcuts()
    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section("App Shortcuts · No Leader Required") {
                ForEach(AppShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        TextField("Shortcut", text: Binding(get: { shortcutDraft[action] }, set: { shortcutDraft[action] = $0 }))
                            .labelsHidden().accessibilityLabel(action.title + " shortcut")
                            .textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                }
                Text("Use cmd+n or cmd+shift+[. Modifiers: cmd, shift, option, ctrl. Leave blank to disable. These shortcuts also work in search fields.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Leader") {
                Picker("Start a command with", selection: $draft.leader) {
                    ForEach(Array("abcdefghijklmnopqrstuvwxyz").map(String.init), id: \.self) { letter in
                        Text("Control–\(letter.uppercased())").tag("ctrl+" + letter)
                    }
                }
                Text("Press the leader, then a command. Press it twice to send it literally to the terminal. Escape cancels; an unfinished sequence expires after 3 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Commands") {
                ForEach(WorkspaceCommand.allCases) { command in
                    HStack {
                        Text(command.title)
                        Spacer()
                        TextField("Keys", text: Binding(get: { draft[command] }, set: { draft[command] = $0 }))
                            .labelsHidden().accessibilityLabel(command.title)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            .frame(width: 150)
                    }
                }
                Text("Case matters: A means Shift-A. Separate successive keys with spaces (S 0), alternatives with commas (h, left). Leave blank to unbind. Digits 1–9 select terminal tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Tools (o), additional agents (c), and remote lifecycle commands are not implemented in this GUI yet. Their CLI bindings are not forwarded into your remote shell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            if let error = shortcutDraft.validationError { Text(error).foregroundStyle(.red).font(.caption) }
            if let error = draft.validationError { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Restore Defaults") { draft = CommandBindings(); shortcutDraft = AppShortcuts() }
                Spacer()
                Button("Save Keybindings") { commands.save(draft); commands.saveAppShortcuts(shortcutDraft) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.validationError != nil || shortcutDraft.validationError != nil || (draft == commands.bindings && shortcutDraft == commands.appShortcuts))
            }
        }.padding(20)
        }.onAppear { draft = commands.bindings; shortcutDraft = commands.appShortcuts }
    }
}

struct CommandsSheet: View {
    @Environment(WorkspaceCommands.self) private var commands
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Workspace commands").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("macOS shortcuts").font(.headline)
                    Text("Press these shortcuts directly; no leader needed.").font(.caption).foregroundStyle(.secondary)
                    ForEach(AppShortcutAction.allCases) { action in
                        HStack { Text(action.title); Spacer(); Text(commands.appShortcuts[action]).font(.caption.monospaced()) }
                    }
                    Divider()
                    Text("Leader shortcuts").font(.headline)
                    Text("Press \(commands.bindings.leader), release it, then press a key below. Press the leader twice to send it to the terminal.").font(.caption).foregroundStyle(.secondary)
                    ForEach(WorkspaceCommand.allCases) { command in
                        Button {
                            dismiss()
                            commands.perform(command)
                        } label: {
                            HStack { Text(command.title); Spacer(); Text(commands.bindings[command]).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }

                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 480, height: 650)
    }
}

private extension AppShortcut {
    var appKitModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = .command
        if shift { flags.insert(.shift) }; if option { flags.insert(.option) }; if control { flags.insert(.control) }
        return flags
    }
    var swiftUIModifiers: EventModifiers {
        var flags: EventModifiers = .command
        if shift { flags.insert(.shift) }; if option { flags.insert(.option) }; if control { flags.insert(.control) }
        return flags
    }
}
