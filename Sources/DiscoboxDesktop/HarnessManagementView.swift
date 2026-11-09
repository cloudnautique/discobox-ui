import SwiftUI
import AppKit
import DiscoboxCore

struct HarnessManagementView: View {
    let harness: Harness
    let manager: HarnessManagement
    let computer: String
    let openBox: (String) -> Void
    let newBox: () -> Void
    let console: () -> Void
    let close: () -> Void
    @State private var reviewed = false
    private var config: JSONValue { manager.details["harness"] }
    private var legacySetup: Bool { manager.details == .null ? harness.usesLegacySetup : config["configured"] != .null }
    var body: some View {
        StudioConfirmation(title: harness.name, symbol: "terminal", subtitle: computer, width: 760) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Sign in inside a box, then review and save that box’s login and settings here to make them available to other boxes using this harness.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Advanced console…", action: console).font(.caption).disabled(legacySetup || !manager.validConnection || manager.busy) }
                    if legacySetup {
                        Notice(text: "This server uses the older harness setup API. The embedded console uses the newer API. Configure this harness with the host’s matching Discobox CLI, or update the server to use save-back here.", symbol: "info.circle")
                    }
                    if manager.details != .null { sharedState }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sign in or update settings").font(.headline)
                        Picker("Source box", selection: Binding(get: { manager.boxID }, set: { manager.selectBox($0); reviewed = false })) {
                            Text("Choose a running box…").tag("")
                            ForEach(manager.boxes) { box in Text(box.displayName).tag(box.id) }
                        }.disabled(manager.busy)
                        HStack {
                            Button("Open box") { openBox(manager.boxID) }.disabled(manager.boxID.isEmpty || manager.busy)
                            Button("New sign-in box…", action: newBox).disabled(manager.busy)
                            Spacer()
                            Button("Review changes") { reviewed = false; Task { await manager.refreshPreview() } }
                                .disabled(manager.boxID.isEmpty || manager.busy || !manager.validConnection)
                                .accessibilityIdentifier("harness.review")
                        }
                        Text("For Claude Code subscriptions, use /login in the box. Saving captures the refreshable login; copying a short-lived access token into Box secrets does not provide automatic renewal.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).studioCard()
                    if manager.review != .null { changeReview }
                    if manager.result != .null { resultView }
                    if let error = manager.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if !manager.validConnection { Text("This computer reconnected or disconnected. Reopen its harness management window.").foregroundStyle(.orange) }
                }.padding(2)
            }.frame(height: 480)
        } footer: {
            HStack {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if manager.busy { ProgressView().controlSize(.small) }
                Button("Reload saved state") { Task { await manager.load() } }.disabled(manager.busy || !manager.validConnection)
                if manager.review != .null {
                    Button("Discard candidate", role: .destructive) { reviewed = false; Task { await manager.answer(save: false) } }.disabled(!manager.canDiscard)
                    Button(manager.changes["state"].string == "saved-handoff-pending" ? "Retry handoff" : "Save reviewed changes") {
                        reviewed = false; Task { await manager.answer(save: true) }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!manager.canSave || !reviewed)
                        .accessibilityIdentifier("harness.save")
                }
            }
        }.task { await manager.load() }
            .onChange(of: manager.review) { reviewed = false }
    }
    private var sharedState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved on this computer’s Discobox server").font(.headline)
            if !manager.details["notice"].string.isEmpty { Text(manager.details["notice"].string).font(.caption).foregroundStyle(.secondary) }
            if manager.details["bindings"].array.isEmpty {
                Text("No shared credential bindings reported. A box may still have its own local login until you save it.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(manager.details["bindings"].array.enumerated()), id: \.offset) { _, binding in
                credentialRow(binding)
            }
            DisclosureGroup("Saved settings files") {
                fileSet("Bundle defaults", files: config["files"].array)
                fileSet("Saved from boxes", files: config["configuredFiles"].array)
                fileSet("Personal overrides", files: config["fileOverrides"].array)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).studioCard()
    }
    private func credentialRow(_ binding: JSONValue) -> some View {
        let secret = manager.details["secrets"].array.first { $0["id"] == binding["secretId"] } ?? .null
        let lifetime = binding["expiresAt"].string
        return VStack(alignment: .leading, spacing: 3) {
            Label(binding["secretName"].string.isEmpty ? binding["secretId"].string : binding["secretName"].string, systemImage: "key")
            Text(bindingDescription(binding, secret: secret)).font(.caption).foregroundStyle(.secondary)
            Text(lifetime.isEmpty ? "Persistent binding · no grant expiry" : "Binding expires " + lifetime).font(.caption).foregroundStyle(lifetime.isEmpty ? Color.secondary : Color.orange)
        }
    }
    private func bindingDescription(_ binding: JSONValue, secret: JSONValue) -> String {
        let variable = binding["envVar"].string
        let kind = secret["type"].string == "oauth" ? "Refreshable login" : secret["type"].string
        return "\(variable) · \(kind)"
    }
    private func fileSet(_ title: String, files: [JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if files.isEmpty { Text("None").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                DisclosureGroup(file["path"].string) { Text(file["content"].string).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }.padding(.top, 8)
    }
    private var changeReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review before sharing").font(.headline)
            LabeledContent("State", value: manager.changes["state"].string)
            if manager.changes["credentials"].array.isEmpty && manager.changes["files"].array.isEmpty {
                Text("No saveable changes were reported. After /login, wait briefly and choose Review changes again. Check any diagnostics below.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(manager.changes["credentials"].array.enumerated()), id: \.offset) { _, credential in
                VStack(alignment: .leading, spacing: 4) {
                    Label(credential["envName"].string, systemImage: "key.fill")
                    Text(credentialDescription(credential)).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(manager.changes["files"].array.enumerated()), id: \.offset) { _, file in
                DisclosureGroup(file["path"].string) {
                    if file["shadowed"] == .bool(true) { Text("Saved beneath a personal override; that override will remain active.").foregroundStyle(.orange).font(.caption) }
                    Text(file["remove"] == .bool(true) ? "Remove saved file or restore its baseline" : "Add or update saved file").font(.caption)
                    Text("Before").font(.caption.weight(.semibold))
                    Text(file["previous"]["content"].string).font(.caption.monospaced()).textSelection(.enabled)
                    Text("After").font(.caption.weight(.semibold))
                    Text(file["file"]["content"].string).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            ForEach(Array(manager.changes["diagnostics"].array.enumerated()), id: \.offset) { _, diagnostic in
                Label(diagnostic["code"].string + ": " + diagnostic["message"].string, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("Save updates shared harness settings and credentials for other boxes using this harness. For OAuth logins, Discobox stores refresh material server-side and creates a persistent harness binding. Token credentials still expire according to their issuer; this is separate from temporary credential-use approvals.").font(.callout).foregroundStyle(.secondary)
            Toggle("I reviewed the files and credentials to share", isOn: $reviewed).toggleStyle(.checkbox).disabled(manager.busy).accessibilityIdentifier("harness.reviewed")
        }.padding(12).studioCard()
    }
    private func credentialDescription(_ credential: JSONValue) -> String {
        let provider = credential["provider"].string
        let type = credential["type"].string
        let account = credential["account"].string
        return [provider, type, account].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func resultTitle(_ state: String) -> String {
        switch state {
        case "saved": "Harness changes saved"
        case "saved-handoff-pending": "Saved · handoff pending"
        case "saved-handoff-superseded": "Saved · handoff superseded"
        case "discarded": "Candidate discarded"
        default: "Server result: " + state
        }
    }
    private var resultView: some View {
        let state = manager.result["state"].string
        return VStack(alignment: .leading, spacing: 6) {
            Label(resultTitle(state), systemImage: "checkmark.circle")
            Text(state == "saved-handoff-pending"
                 ? "The shared configuration is committed. Discobox is still handing the accepted login back to the source box. Refresh the review to check it or retry that handoff; signing in again is not required for this receipt."
                 : state == "saved-handoff-superseded" ? "Saved, but a newer harness or binding change superseded the source-box handoff. Reload shared state to inspect what applies now."
                 : state == "discarded" ? "The candidate was discarded. The box’s local files are unchanged."
                 : "Reload saved state to see the shared credentials.").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).studioCard()
    }
}

@MainActor final class HarnessSetupWindows {
    static let shared = HarnessSetupWindows()
    private var windows: [String: HarnessManagementWindow] = [:]
    func close(connection: UUID) {
        for key in Array(windows.keys) where key.hasPrefix(connection.uuidString + ":") { windows.removeValue(forKey: key)?.window.close() }
        HarnessConsoleWindows.shared.close(connection: connection)
    }
    func closeAll() {
        for controller in Array(windows.values) { controller.window.close() }
        windows.removeAll(); HarnessConsoleWindows.shared.closeAll()
    }
    func open(_ harness: Harness, workspace: Workspace, connections: Connections? = nil, commands: WorkspaceCommands? = nil, sourceBoxID: String? = nil) {
        guard workspace.isConnected, !workspace.isDemo else { return }
        let generation = workspace.connectionID
        let key = generation.uuidString + ":" + harness.id
        if let existing = windows[key] {
            if let sourceBoxID { existing.selectSource(sourceBoxID) }
            existing.window.makeKeyAndOrderFront(nil); return
        }
        let host = connections?.sessions.first { $0.workspace === workspace }
        let manager = HarnessManagement(workspace: workspace, harnessID: harness.id)
        if let sourceBoxID { manager.selectBox(sourceBoxID) }
        let controller = HarnessManagementWindow(harness: harness, manager: manager, computer: host?.profile.displayName ?? workspace.endpointLabel,
            computerID: host?.id, connections: connections, commands: commands, openBox: { boxID in
                Task {
                    guard workspace.connectionID == generation, workspace.isConnected else { return }
                    if let connections, let host { await connections.selectBox(.init(connection: host.id, box: boxID)) }
                    else { await workspace.selectBox(boxID) }
                    guard workspace.connectionID == generation else { return }
                    commands?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                }
            }, console: { HarnessConsoleWindows.shared.open(harness, workspace: workspace) }, onClose: { [weak self] in self?.windows.removeValue(forKey: key) })
        windows[key] = controller; controller.window.makeKeyAndOrderFront(nil)
    }
}

@MainActor private final class HarnessManagementWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let manager: HarnessManagement
    private let onClose: () -> Void
    init(harness: Harness, manager: HarnessManagement, computer: String, computerID: String?, connections: Connections?, commands: WorkspaceCommands?, openBox: @escaping (String) -> Void, console: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.manager = manager; self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 690), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Manage " + harness.name; window.isReleasedWhenClosed = false; window.delegate = self
        var root = AnyView(HarnessManagementHost(harness: harness, manager: manager, computer: computer, computerID: computerID, openBox: openBox, console: console, close: { [weak self] in self?.window.close() }).environment(manager.workspace))
        if let connections { root = AnyView(root.environment(connections)) }
        if let commands { root = AnyView(root.environment(commands)) }
        window.contentView = NSHostingView(rootView: root); window.center()
    }
    func selectSource(_ id: String) { manager.selectBox(id) }
    func windowWillClose(_ notification: Notification) { manager.close(); onClose() }
}

private struct HarnessManagementHost: View {
    let harness: Harness
    let manager: HarnessManagement
    let computer: String
    let computerID: String?
    let openBox: (String) -> Void
    let console: () -> Void
    let close: () -> Void
    @State private var showNewBox = false
    var body: some View {
        HarnessManagementView(harness: harness, manager: manager, computer: computer, openBox: openBox, newBox: { showNewBox = true }, console: console, close: close)
            .sheet(isPresented: $showNewBox) { NewBoxSheet(computer: computerID, harnessID: harness.id).environment(manager.workspace) }
    }
}
