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
    @State private var showingReview: Bool
    @State private var confirmingDiscard = false
    @State private var activity: Activity?
    @State private var failedActivity: Activity = .load
    private enum Activity { case load, review, save, discard }

    init(harness: Harness, manager: HarnessManagement, computer: String, openBox: @escaping (String) -> Void,
         newBox: @escaping () -> Void, console: @escaping () -> Void, close: @escaping () -> Void) {
        self.harness = harness; self.manager = manager; self.computer = computer
        self.openBox = openBox; self.newBox = newBox; self.console = console; self.close = close
        _showingReview = State(initialValue: manager.review != .null)
    }
    private var config: JSONValue { manager.details["harness"] }
    private var legacySetup: Bool { manager.details == .null ? harness.usesLegacySetup : config["configured"] != .null }
    private var sourceName: String { manager.workspace.sandboxes.first { $0.id == manager.boxID }?.displayName ?? "Selected box" }
    private var handoffPending: Bool { manager.changes["state"].string == "saved-handoff-pending" }
    private var blocked: Bool { manager.busy || !manager.validConnection }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DiscoboxAppearance.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if legacySetup {
                        Notice(text: "This server uses an older harness setup API. Use the host’s matching Discobox CLI to configure it, or update the server to save changes here.", symbol: "info.circle")
                    }
                    if showingReview { changeReview.id(manager.review["fingerprint"].string) } else { overview }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(DiscoboxAppearance.border)
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        .background(DiscoboxAppearance.surface).tint(DiscoboxAppearance.accent)
        .task(id: manager.reviewRevision) {
            if manager.details == .null { await manager.load() }
            if manager.reviewRevision > 0 { await manager.refreshPreview() }
        }
        .onChange(of: manager.review) { _, value in reviewed = false; showingReview = value != .null }
        .onChange(of: manager.boxID) { reviewed = false; showingReview = false }
        .sheet(isPresented: $confirmingDiscard) {
            StudioMessageSheet(title: "Discard unsaved changes?", symbol: "arrow.uturn.backward",
                message: "Discard the reviewed changes from “\(sourceName)”? This does not change the shared harness configuration or the box’s local files.",
                confirmTitle: "Discard changes", destructive: true, defaultConfirm: false, cancel: { confirmingDiscard = false }) {
                confirmingDiscard = false; run(.discard)
            }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: showingReview ? "square.and.arrow.up" : "terminal")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(DiscoboxAppearance.accent)
                .frame(width: 38, height: 38).background(DiscoboxAppearance.selection, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(harness.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Text(showingReview ? "Save changes from “\(sourceName)”" : "Login and configuration")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Label(computer, systemImage: "desktopcomputer").font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200).help(computer)
            Menu {
                Button("Refresh saved state") { run(.load) }.disabled(blocked)
                if showingReview { Button("Refresh changes") { run(.review) }.disabled(blocked) }
                Divider()
                Button("New box to sign in…", action: newBox).disabled(blocked)
                Button("Advanced console…", action: console).disabled(legacySetup || blocked)
                if showingReview {
                    Divider()
                    Button("Discard unsaved changes…", role: .destructive) { confirmingDiscard = true }.disabled(!manager.canDiscard)
                }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Harness actions").accessibilityLabel("Harness actions")
        }.padding(.horizontal, 24).padding(.vertical, 18).background(DiscoboxAppearance.chrome)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            if manager.result != .null { resultView }
            if manager.details != .null {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Saved login")
                    if manager.details["bindings"].array.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No shared login saved", systemImage: "key").font(.system(size: 13, weight: .medium))
                            Text("Sign in inside a box, then save its login here for other boxes using this harness.").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).studioCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(manager.details["bindings"].array.enumerated()), id: \.offset) { index, binding in
                                if index > 0 { Divider() }
                                credentialRow(binding).padding(14)
                            }
                        }.studioCard()
                    }
                    if !manager.details["notice"].string.isEmpty { Text(manager.details["notice"].string).font(.caption).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Configuration")
                    VStack(spacing: 0) {
                        HarnessSavedFiles(title: "Saved files", files: config["configuredFiles"].array)
                        Divider().padding(.leading, 14)
                        HarnessSavedFiles(title: "Personal overrides", files: config["fileOverrides"].array)
                        Divider().padding(.leading, 14)
                        HarnessSavedFiles(title: "Bundle defaults", files: config["files"].array)
                    }.studioCard()
                }
                if !config["bundle"].string.isEmpty || !config["extends"].string.isEmpty || !config["image"].string.isEmpty {
                    DisclosureGroup("Harness software") {
                        VStack(alignment: .leading, spacing: 6) {
                            if !config["extends"].string.isEmpty {
                                Text("Based on " + parentName).font(.callout)
                                Text("Follows its parent’s bundle, with separate saved login and settings.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(config["bundle"].string.isEmpty ? config["image"].string : config["bundle"].string)
                                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Text("The software bundle is separate from this harness’s saved account.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                }
            } else if manager.busy {
                ProgressView("Loading saved login and settings…").controlSize(.small).padding(.vertical, 12)
            }
            HarnessLaunchSettings(harness: harness, workspace: manager.workspace)
            sourceChooser
        }
    }
    private var parentName: String {
        let id = config["extends"].string
        return manager.workspace.cachedHarnesses.first { $0.id == id }?.name ?? id
    }
    private var sourceChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Save changes from a box")
            VStack(alignment: .leading, spacing: 14) {
                if manager.boxes.isEmpty {
                    Text("Start a box with this harness to sign in or change its settings.").font(.callout).foregroundStyle(.secondary)
                    Button("New box to sign in…", action: newBox).disabled(blocked)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox").foregroundStyle(.secondary)
                        StudioMenuPicker(title: "Source box", selection: Binding(get: { manager.boxID }, set: { manager.selectBox($0); reviewed = false }),
                            options: [.init(id: "", title: "Choose a running box…")] + manager.boxes.map { .init(id: $0.id, title: $0.displayName) }, alignment: .left)
                            .disabled(blocked)
                    }
                    HStack {
                        Button("Open box") { openBox(manager.boxID) }.disabled(manager.boxID.isEmpty || blocked)
                        Button("New box to sign in…", action: newBox).disabled(blocked).font(.system(size: 12))
                        Spacer()
                        Button("Review changes", systemImage: "arrow.right") { run(.review) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(manager.boxID.isEmpty || blocked || legacySetup).accessibilityIdentifier("harness.review")
                    }
                }
            }.padding(14).studioCard()
            if manager.details["bindings"].array.isEmpty {
                DisclosureGroup("How to sign in") {
                    Text("Open the box and sign in to the harness. For Claude Code, use /login. Return here and review the changes to save the login and settings.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                    Text("A copied access token does not include the refresh credentials needed for automatic renewal.").font(.caption).foregroundStyle(.secondary)
                }.font(.system(size: 12))
            }
        }
    }
    private func credentialRow(_ binding: JSONValue) -> some View {
        let secret = manager.details["secrets"].array.first { $0["id"] == binding["secretId"] } ?? .null
        let oauth = secret["type"].string == "oauth"
        let name = binding["secretName"].string.isEmpty ? "Saved credential" : binding["secretName"].string
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Environment variable", value: binding["envVar"].string)
                LabeledContent("Shared access", value: bindingLifetime(binding))
                Text(oauth ? "Refresh credentials are stored on the server. The provider may still require you to sign in again." : "This credential follows its issuer’s expiry policy.")
                    .foregroundStyle(.secondary)
            }.font(.caption).padding(.top, 10).textSelection(.enabled)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "key").foregroundStyle(DiscoboxAppearance.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 13, weight: .medium))
                    Text(oauth ? "Login saved · Refreshable OAuth" : "Credential saved")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
    private func bindingLifetime(_ binding: JSONValue) -> String {
        let value = binding["expiresAt"].string
        guard !value.isEmpty else { return "No binding expiry" }
        if let date = ISO8601DateFormatter().date(from: value) { return "Expires " + date.formatted(date: .abbreviated, time: .shortened) }
        return "Expires " + value
    }
    private var changeReview: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reviewTitle).font(.system(size: 16, weight: .semibold))
                Text("Save for \(harness.name) · \(computer) · project \(manager.workspace.projectID ?? "").")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open source box") { openBox(manager.boxID) }.disabled(manager.boxID.isEmpty || blocked)
            Text("This updates the shared login and settings for this harness on this server. Other computers and account variants are separate. New boxes receive the saved settings; existing boxes keep their local settings. Replacing a shared login affects boxes already using that credential. Settings may include hooks and commands.")
                .font(.caption).foregroundStyle(.secondary)
            if let explanation = HarnessCapture.explanation(manager.changes) {
                Label(explanation, systemImage: manager.changes["state"].string == "unsupported" ? "info.circle" : "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if handoffPending {
                Label("Your changes are saved. You can retry updating the source box without signing in again.", systemImage: "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if HarnessCapture.explanation(manager.changes) == nil && manager.changes["credentials"].array.isEmpty && manager.changes["files"].array.isEmpty && !handoffPending {
                Label("No changes to save", systemImage: "checkmark.circle").font(.callout)
                Text("After signing in or changing settings, wait briefly and check again.").font(.callout).foregroundStyle(.secondary)
            }
            if !manager.changes["credentials"].array.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Login and credentials")
                    VStack(spacing: 0) {
                        ForEach(Array(manager.changes["credentials"].array.enumerated()), id: \.offset) { index, credential in
                            if index > 0 { Divider() }
                            VStack(alignment: .leading, spacing: 5) {
                                Label(credential["account"].string.isEmpty ? credential["envName"].string : credential["account"].string, systemImage: "key")
                                    .font(.system(size: 13, weight: .medium))
                                Text(credentialDescription(credential)).font(.caption).foregroundStyle(.secondary)
                                Text(existingCredentialDescription(credential)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                    }.studioCard()
                }
            }
            if !manager.changes["files"].array.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Configuration changes")
                    VStack(spacing: 0) {
                        ForEach(Array(manager.changes["files"].array.enumerated()), id: \.offset) { index, file in
                            if index > 0 { Divider() }
                            HarnessFileChangeView(file: file).padding(14)
                        }
                    }.studioCard()
                }
            }
            ForEach(Array(manager.changes["diagnostics"].array.enumerated()), id: \.offset) { _, diagnostic in
                Label(diagnosticDescription(diagnostic), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }
    private var reviewTitle: String {
        if handoffPending { return "Saved · source box update pending" }
        let logins = manager.changes["credentials"].array.count
        let files = manager.changes["files"].array.count
        let parts = [logins > 0 ? "\(logins) credential update\(logins == 1 ? "" : "s")" : "", files > 0 ? "\(files) file change\(files == 1 ? "" : "s")" : ""]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ").isEmpty ? "Review changes" : parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func existingCredentialDescription(_ credential: JSONValue) -> String {
        let existing = manager.details["bindings"].array.filter { $0["envVar"] == credential["envName"] }
        let names = existing.map { $0["secretName"].string }.filter { !$0.isEmpty }
        return names.isEmpty ? "No existing shared login reported for this variable." : "Replaces shared login: " + names.joined(separator: ", ")
    }
    private func credentialDescription(_ credential: JSONValue) -> String {
        let kind = credential["type"].string == "oauth" ? "Refreshable OAuth" : credential["type"].string
        return [credential["provider"].string, kind, credential["envName"].string].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func diagnosticDescription(_ diagnostic: JSONValue) -> String { diagnostic["code"].string + ": " + diagnostic["message"].string }
    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !manager.validConnection {
                Label("This computer disconnected or reconnected. Reopen harness management to continue.", systemImage: "network.slash").font(.callout).foregroundStyle(.orange)
            } else if let error = manager.error {
                HStack(alignment: .top, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(failedActivity == .load ? "Retry loading" : "Review again") { run(failedActivity == .load ? .load : .review) }
                        .disabled(blocked)
                }
            }
            if showingReview && (manager.canSave || manager.busy && activity == .save) {
                Toggle(handoffPending ? "Retry updating the source box with the saved changes" : "Share these login and configuration changes", isOn: $reviewed)
                    .toggleStyle(.checkbox).font(.system(size: 12)).disabled(blocked).accessibilityIdentifier("harness.reviewed")
            }
            HStack {
                if showingReview {
                    Button("Back") { reviewed = false; showingReview = false }.keyboardShortcut(.cancelAction).disabled(manager.busy)
                } else {
                    Spacer()
                }
                if manager.busy {
                    ProgressView().controlSize(.small)
                    Text(activityLabel).font(.caption).foregroundStyle(.secondary)
                }
                if showingReview {
                    Spacer()
                    if manager.canSave || manager.busy && activity == .save {
                        Button(handoffPending ? "Retry box update" : "Save changes") { run(.save) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!manager.canSave || !reviewed)
                            .accessibilityIdentifier("harness.save")
                    } else {
                        Button("Check again") { run(.review) }.disabled(blocked)
                    }
                } else {
                    Button("Done", action: close).keyboardShortcut(.cancelAction)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(DiscoboxAppearance.chrome)
    }
    private var activityLabel: String {
        switch activity {
        case .review: "Checking box changes…"
        case .save: "Saving changes…"
        case .discard: "Discarding changes…"
        default: "Refreshing saved state…"
        }
    }
    private func run(_ next: Activity) {
        guard !blocked else { return }
        reviewed = false; activity = next; failedActivity = next
        Task {
            switch next {
            case .load: await manager.load()
            case .review: await manager.refreshPreview()
            case .save, .discard:
                await manager.answer(save: next == .save)
                if manager.result != .null {
                    showingReview = false; failedActivity = .load; activity = .load
                    await manager.load()
                }
            }
            activity = nil
        }
    }
    private var resultView: some View {
        let state = manager.result["state"].string
        return VStack(alignment: .leading, spacing: 8) {
            Label(resultTitle(state), systemImage: state == "saved" || state == "discarded" ? "checkmark.circle" : "info.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(resultDescription(state)).font(.callout).foregroundStyle(.secondary)
            if state == "saved-handoff-pending" {
                Button("Check box update") { run(.review) }.disabled(blocked)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).studioCard()
    }
    private func resultTitle(_ state: String) -> String {
        switch state {
        case "saved": "Login and configuration saved"
        case "saved-handoff-pending": "Saved · finishing the box update"
        case "saved-handoff-superseded": "Saved · newer changes are in use"
        case "discarded": "Unsaved changes discarded"
        default: "Check the save result"
        }
    }
    private func resultDescription(_ state: String) -> String {
        switch state {
        case "saved": "These changes are saved on \(computer) for boxes using this harness."
        case "saved-handoff-pending": "The shared settings and login are saved. The source box is still being updated; you do not need to sign in again for this save."
        case "saved-handoff-superseded": "The changes were saved, but a newer change now takes precedence for the source box. Refresh saved state to see what applies."
        case "discarded": "The shared harness configuration and the box’s local files were left unchanged."
        default: "The server returned a result this app does not recognize. Refresh saved state and review again before retrying."
        }
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
        if let sourceBoxID { manager.requestReview(box: sourceBoxID) }
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = harness.name + " · Shared login and settings"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: 620, height: 560)
        var root = AnyView(HarnessManagementHost(harness: harness, manager: manager, computer: computer, computerID: computerID, openBox: openBox, console: console, close: { [weak self] in self?.window.close() }).environment(manager.workspace))
        if let connections { root = AnyView(root.environment(connections)) }
        if let commands { root = AnyView(root.environment(commands)) }
        window.contentView = NSHostingView(rootView: root); window.center()
    }
    func selectSource(_ id: String) { manager.requestReview(box: id) }
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
            .sheet(isPresented: $showNewBox) { NewBoxSheet(computer: computerID, harnessID: harness.id, onCreated: { box in
                guard manager.validConnection, box.projectId == manager.workspace.projectID, box.config.harnessConfigId == harness.id else { return }
                manager.requestReview(box: box.id)
            }).environment(manager.workspace) }
    }
}
