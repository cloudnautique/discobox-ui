import SwiftUI
import AppKit
import DiscoboxCore

struct HarnessSettings: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(WorkspaceCommands.self) private var commands: WorkspaceCommands?
    @State private var error: String?
    @State private var loading = false
    @State private var savingDefault = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudioDialogHeader(title: "Harnesses", symbol: "terminal", subtitle: "Shared logins, settings and launch defaults on the selected computer.")
            if !workspace.isConnected {
                ContentUnavailableView("Connect to Discobox", systemImage: "network", description: Text("Choose a server in Connection settings."))
            } else {
                Text("The default is shared with other Discobox clients on this computer and project. New boxes preselect it; existing boxes keep their harness.").font(.caption).foregroundStyle(.secondary)
                Text(workspace.endpointLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                List(workspace.cachedHarnesses) { harness in
                    HStack(spacing: 12) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(harness.name).fontWeight(.medium)
                                if harness.id == workspace.defaultHarnessID { Text("Default").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(harness.usesLegacySetup ? (harness.configured ? "Configured" : "Needs setup") : "Sign in inside a box · review changes to share")
                                .font(.caption).foregroundStyle(harness.configured ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        if harness.id != workspace.defaultHarnessID {
                            Button("Make Default") { Task { await makeDefault(harness.id) } }
                                .disabled(loading || savingDefault || !harness.configured || workspace.isDemo)
                        }
                        Button("Login & Settings…") {
                            HarnessSetupWindows.shared.open(harness, workspace: workspace, connections: connections, commands: commands)
                        }.disabled(workspace.isDemo)
                    }.padding(.vertical, 6)
                }.listStyle(.plain).scrollContentBackground(.hidden).studioCard()
                HStack {
                    if loading || savingDefault { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }.disabled(loading || savingDefault)
                }
            }
        }.padding(24).background(DiscoboxAppearance.surface).tint(DiscoboxAppearance.accent)
        .task(id: workspace.connectionID) { error = nil; await refresh() }
    }

    private func makeDefault(_ harnessID: String) async {
        let connection = workspace.connectionID
        savingDefault = true; error = nil
        defer { savingDefault = false }
        do { try await workspace.setDefaultHarness(harnessID, connection: connection) }
        catch { if connection == workspace.connectionID { self.error = error.localizedDescription } }
    }

    private func refresh() async {
        guard workspace.isConnected else { return }
        let connection = workspace.connectionID
        loading = true; error = nil
        defer { loading = false }
        do {
            _ = try await workspace.harnesses(force: true)
            try await workspace.refreshDefaultHarness()
        } catch {
            guard connection == workspace.connectionID else { return }
            self.error = error.localizedDescription
        }
    }
}

struct CredentialSettings: View {
    @Environment(Workspace.self) private var workspace
    @State private var credentials: [JSONValue] = []
    @State private var details: CredentialDetailsRequest?
    @State private var search = ""
    @State private var pendingDelete: JSONValue?
    @State private var pendingDeleteConnection: UUID?
    @State private var error: String?
    @State private var busy = false

    private var matches: [JSONValue] {
        credentials.filter { item in
            search.isEmpty || ["name", "type", "host"].contains { item[$0].string.localizedCaseInsensitiveContains(search) }
        }.sorted { $0["name"].string.localizedStandardCompare($1["name"].string) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudioDialogHeader(title: "Credentials", symbol: "key", subtitle: "Stored credentials on the selected computer.")
            if !workspace.isConnected {
                ContentUnavailableView("Connect to Discobox", systemImage: "network", description: Text("Choose a server in Connection settings."))
            } else {
                Text(workspace.endpointLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                TextField("Search credentials", text: $search).textFieldStyle(.roundedBorder)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                List(matches, id: \.["id"].string) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "key").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item["name"].string).fontWeight(.medium)
                            Text([item["type"].string, item["host"].string].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Details…") { details = .init(secret: item, connection: workspace.connectionID) }
                            .disabled(busy || workspace.isDemo)
                        Button("Delete…", role: .destructive) {
                            pendingDeleteConnection = workspace.connectionID
                            pendingDelete = item
                        }
                            .disabled(busy || workspace.isDemo)
                    }.padding(.vertical, 6)
                }
                .listStyle(.plain).scrollContentBackground(.hidden).studioCard()
                .overlay {
                    if matches.isEmpty && !busy {
                        Text(credentials.isEmpty ? "No stored credentials" : "No matching credentials").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }.disabled(busy)
                }
            }
        }.padding(24).background(DiscoboxAppearance.surface).tint(DiscoboxAppearance.accent)
        .task(id: workspace.connectionID) {
            credentials = []; pendingDelete = nil; error = nil
            await refresh()
        }
        .sheet(item: $details) { request in
            CredentialDetailsView(request: request) { Task { await refresh() } }.environment(workspace)
        }
        .sheet(isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let item = pendingDelete, let connection = pendingDeleteConnection {
                StudioMessageSheet(title: "Delete credential?", symbol: "key", message: "Delete \(item["name"].string) from this server? Access depending on it may stop working. This cannot be undone.",
                    confirmTitle: "Delete", destructive: true, defaultConfirm: false, cancel: { pendingDelete = nil }) {
                        pendingDelete = nil
                        Task { await delete(item, connection: connection) }
                    }
            }
        }
    }

    private func refresh() async {
        guard workspace.isConnected else { return }
        let connection = workspace.connectionID
        busy = true; error = nil
        defer { busy = false }
        do {
            let items = try await workspace.approvalSecrets()
            guard connection == workspace.connectionID else { return }
            credentials = items
        } catch {
            guard connection == workspace.connectionID else { return }
            self.error = error.localizedDescription
        }
    }

    private func delete(_ item: JSONValue, connection: UUID) async {
        guard connection == workspace.connectionID, workspace.isConnected else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await workspace.operation(.deleteSecret, requestID: item["id"].string)
            guard connection == workspace.connectionID else { return }
            credentials.removeAll { $0["id"].string == item["id"].string }
        } catch {
            guard connection == workspace.connectionID else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor final class HarnessConsoleWindows {
    static let shared = HarnessConsoleWindows()
    private var windows: [String: HarnessSetupWindow] = [:]
    func close(connection: UUID) {
        for key in Array(windows.keys) where key.hasPrefix(connection.uuidString + ":") {
            windows.removeValue(forKey: key)?.window.close()
        }
    }
    func closeAll() {
        for controller in Array(windows.values) { controller.window.close() }
        windows.removeAll()
    }
    func open(_ harness: Harness, workspace: Workspace) {
        guard workspace.isConnected, !workspace.isDemo, let project = workspace.projectID else { return }
        let key = "\(workspace.connectionID):harnesses"
        if let existing = windows[key] {
            if existing.isFinished { existing.window.close() }
            else { existing.window.makeKeyAndOrderFront(nil); return }
        }
        let session = TerminalSession(arguments: ["--configure-harness", harness.id, "--endpoint", workspace.transportEndpoint, "--project", project])
        session.view.openURL = { raw in
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
            return NSWorkspace.shared.open(url)
        }
        let controller = HarnessSetupWindow(harness: harness, session: session, workspace: workspace) { [weak self] in
            self?.windows.removeValue(forKey: key)
        }
        windows[key] = controller
        controller.window.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class HarnessSetupWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let session: TerminalSession
    private let onClose: () -> Void
    var isFinished: Bool { session.ended || session.error != nil }
    init(harness: Harness, session: TerminalSession, workspace: Workspace, onClose: @escaping () -> Void) {
        self.session = session; self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Manage Harnesses"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        window.delegate = self
        window.contentView = NSHostingView(rootView: HarnessSetupContent(session: session, connection: workspace.connectionID, close: { [weak self] in self?.window.close() }).environment(workspace))
        window.center()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isFinished else { return true }
        return StudioAppKitDialog.confirm(title: "Close harness management?", symbol: "terminal",
            message: "This closes the harness console. Unsaved changes in its current editor may be lost.",
            confirmTitle: "Close Console", destructive: true, defaultConfirm: false)
    }
    func windowWillClose(_ notification: Notification) { session.close(); onClose() }
}

private struct HarnessSetupContent: View {
    @Environment(Workspace.self) private var workspace
    let session: TerminalSession
    let connection: UUID
    let close: () -> Void
    @State private var refreshError: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.ended ? "Harness console closed — see terminal for the result" : "Manage saved harness files and settings in the console below")
                Spacer()
            }.font(.system(size: 12)).padding(12).background(DiscoboxAppearance.chrome)
            Divider()
            if let error = session.error ?? refreshError { Text(error).foregroundStyle(.red).padding(8) }
            TerminalSurface(view: session.view, focused: true, onFocus: nil)
            Divider()
            HStack { Spacer(); Button("Close", action: close) }.padding(12).background(DiscoboxAppearance.chrome)
        }
        .background(DiscoboxAppearance.canvas).tint(DiscoboxAppearance.accent)
        .onChange(of: session.ended) { _, ended in
            if ended, connection == workspace.connectionID {
                Task {
                    do { _ = try await workspace.harnesses(force: true) }
                    catch { refreshError = error.localizedDescription }
                }
            }
        }
        .onChange(of: workspace.connectionID) { _, _ in session.close(); close() }
    }
}
