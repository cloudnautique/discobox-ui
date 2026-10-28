import SwiftUI
import AppKit
import DiscoboxCore

struct HarnessSettings: View {
    @Environment(Workspace.self) private var workspace
    @State private var error: String?
    @State private var loading = false
    @State private var defaultID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Harnesses").font(.title2.bold())
            Text("Configure the harnesses on your connected Discobox server.").foregroundStyle(.secondary)
            if !workspace.isConnected {
                ContentUnavailableView("Connect to Discobox", systemImage: "network", description: Text("Choose a server in Connection settings."))
            } else {
                Text(workspace.endpointLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                List(workspace.cachedHarnesses) { harness in
                    HStack(spacing: 12) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(harness.name).fontWeight(.medium)
                                if harness.id == defaultID { Text("Default").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(harness.configured ? "Configured" : "Needs setup")
                                .font(.caption).foregroundStyle(harness.configured ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Button(harness.configured ? "Reconfigure…" : "Configure…") {
                            HarnessSetupWindows.shared.open(harness, workspace: workspace)
                        }.disabled(workspace.isDemo)
                    }.padding(.vertical, 6)
                }
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }.disabled(loading)
                }
            }
        }.padding(24)
        .task(id: workspace.connectionID) { defaultID = ""; error = nil; await refresh() }
    }

    private func refresh() async {
        guard workspace.isConnected else { return }
        let connection = workspace.connectionID
        loading = true; error = nil
        defer { loading = false }
        do {
            _ = try await workspace.harnesses(force: true)
            let project = try await workspace.operation(.defaultProject)
            guard connection == workspace.connectionID else { return }
            defaultID = project["defaultHarnessConfigId"].string
        } catch {
            guard connection == workspace.connectionID else { return }
            self.error = error.localizedDescription
        }
    }
}

struct CredentialSettings: View {
    @Environment(Workspace.self) private var workspace
    @State private var credentials: [JSONValue] = []
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
            Text("Credentials").font(.title2.bold())
            Text("Stored credentials on your connected Discobox server.").foregroundStyle(.secondary)
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
                        Button("Delete…", role: .destructive) {
                            pendingDeleteConnection = workspace.connectionID
                            pendingDelete = item
                        }
                            .disabled(busy || workspace.isDemo)
                    }.padding(.vertical, 6)
                }
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
        }.padding(24)
        .task(id: workspace.connectionID) {
            credentials = []; pendingDelete = nil; error = nil
            await refresh()
        }
        .alert("Delete credential?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                guard let item = pendingDelete, let connection = pendingDeleteConnection else { return }
                pendingDelete = nil
                Task { await delete(item, connection: connection) }
            }
        } message: {
            Text("Delete \(pendingDelete?["name"].string ?? "this credential") from this server? Access depending on it may stop working. This cannot be undone.")
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

@MainActor final class HarnessSetupWindows {
    static let shared = HarnessSetupWindows()
    private var windows: [String: HarnessSetupWindow] = [:]
    func closeAll() {
        for controller in Array(windows.values) { controller.window.close() }
        windows.removeAll()
    }
    func open(_ harness: Harness, workspace: Workspace) {
        guard workspace.isConnected, !workspace.isDemo, let project = workspace.projectID else { return }
        let key = "\(workspace.connectionID):\(harness.id)"
        if let existing = windows[key] {
            if existing.isFinished { existing.window.close() }
            else { existing.window.makeKeyAndOrderFront(nil); return }
        }
        let session = TerminalSession(arguments: ["--configure-harness", harness.id, "--endpoint", workspace.transportEndpoint, "--project", project])
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
        window.title = "Configure \(harness.name)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        window.delegate = self
        window.contentView = NSHostingView(rootView: HarnessSetupContent(session: session, connection: workspace.connectionID, close: { [weak self] in self?.window.close() }).environment(workspace))
        window.center()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isFinished else { return true }
        let alert = NSAlert()
        alert.messageText = "Close harness setup?"
        alert.informativeText = "This detaches the setup terminal. Setup may remain unfinished on the server; closing does not save it."
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Close Setup")
        return alert.runModal() == .alertSecondButtonReturn
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
                Text(session.ended ? "Setup finished — see terminal for the result" : "Follow the harness setup instructions below")
                Spacer()
            }.padding(12)
            Divider()
            if let error = session.error ?? refreshError { Text(error).foregroundStyle(.red).padding(8) }
            TerminalSurface(view: session.view, focused: true, onFocus: nil)
            Divider()
            HStack { Spacer(); Button("Close", action: close) }.padding(12)
        }
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
