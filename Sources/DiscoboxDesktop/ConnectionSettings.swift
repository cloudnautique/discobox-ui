import SwiftUI
import AppKit
import DiscoboxCore

@MainActor enum ConnectionClients {
    static func make(_ profile: ConnectionProfile) throws -> CompanionClient {
        CompanionClient(executable: CompanionLocation.executable, endpoint: profile.endpoint,
            identitySeed: profile.isRemote ? try IrohIdentity.seed() : nil,
            relayURLs: profile.relayURLs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            directOnly: profile.directOnly ?? false)
    }
}

struct ConnectionSettings: View {
    @Environment(Connections.self) private var connections: Connections?
    @Environment(Workspace.self) private var workspace
    @AppStorage("serverEndpoint") private var lastEndpoint = "unix://"
    @AppStorage("savedConnections") private var savedConnections = "[]"
    @AppStorage("computerName") private var computerName = ""
    @State private var selected: String? = "unix://"
    @State private var editor: EditRequest?
    @State private var removing: ConnectionProfile?
    @State private var error: String?
    @State private var needsAuthorization: Set<String> = []
    private struct EditRequest: Identifiable { let id = UUID(); let profile: ConnectionProfile? }
    private var profiles: [ConnectionProfile] { [.localComputer(name: computerName)] + (ConnectionProfiles.decode(savedConnections) ?? []) }
    private var selection: ConnectionProfile? { profiles.first { $0.id == selected } }
    private func connected(_ profile: ConnectionProfile) -> Bool {
        if let connections { return connections.session(profile.endpoint)?.workspace.isConnected == true }
        return workspace.isConnected && !workspace.isDemo && ConnectionProfiles.normalizedEndpoint(workspace.endpointLabel) == profile.endpoint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connections").font(.title2.weight(.semibold))
                Spacer()
                Button { editor = EditRequest(profile: nil) } label: { Label("Add Connection", systemImage: "plus") }
                    .accessibilityIdentifier("connections.add")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("This computer’s name")
                    TextField("This computer’s name", text: $computerName, prompt: Text(ComputerIdentity.systemName))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityIdentifier("connections.computerName")
                }
                Text("Used in the sidebar and remote peer registration commands. Leave blank to use the system computer name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(selection: $selected) {
                ForEach(profiles) { profile in
                    HStack(spacing: 12) {
                        Image(systemName: profile.endpoint == "unix://" ? "desktopcomputer" : "network")
                            .font(.title3).foregroundStyle(.secondary).frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName).font(.body.weight(.medium))
                            Text(profile.endpoint == "unix://" ? "Default local Discobox server" : profile.subtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if connected(profile) {
                            Label("Connected", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
                        } else if needsAuthorization.contains(profile.id) {
                            Text("Needs authorization").foregroundStyle(.orange).font(.caption)
                        } else { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 9).tag(profile.id)
                    .contextMenu {
                        Button(connected(profile) ? "Show Boxes" : "Connect") { connect(profile) }.disabled(connecting(profile))
                        if connected(profile), let connections { Button("Disconnect") { connections.disconnect(profile.id) } }
                        if profile.endpoint != "unix://" {
                            Button("Edit…") { editor = EditRequest(profile: profile) }
                            Button("Copy Address") { copy(profile.endpoint) }
                            Divider()
                            Button("Remove…", role: .destructive) { removing = profile }
                        }
                    }
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                .frame(minHeight: 160)
                .onDeleteCommand { if let selection, selection.endpoint != "unix://" { removing = selection } }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Edit…") { if let selection { editor = EditRequest(profile: selection) } }
                    .disabled(selection == nil || selected == "unix://")
                Button("Remove…") { removing = selection }
                    .disabled(selection == nil || selected == "unix://")
                Spacer()
                if let selection, connected(selection), let connections {
                    Button("Disconnect") { connections.disconnect(selection.id) }
                }
                if selection.map(connecting) == true { ProgressView().controlSize(.small) }
                Button(selection.map(connected) == true ? "Show Boxes" : "Connect") { if let selection { connect(selection) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil || selection.map(connecting) == true)
            }
            Text("Connect to several computers at once. Show Boxes selects a computer without disconnecting the others.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
        .task {
            // Collapse only aliases of the current default socket, never custom sockets.
            if let migrated = ConnectionProfiles.decode(savedConnections), let text = ConnectionProfiles.encode(migrated), text != savedConnections { savedConnections = text }
            let current = ConnectionProfiles.normalizedEndpoint(workspace.endpointLabel)
            selected = profiles.first(where: { $0.endpoint == current })?.id ?? "unix://"
        }
        .sheet(item: $editor) { request in
            ConnectionEditor(profile: request.profile, save: { profile in
                var saved = (ConnectionProfiles.decode(savedConnections) ?? []).filter { $0.endpoint != request.profile?.endpoint && $0.endpoint != profile.endpoint }
                if profile.endpoint != "unix://" { saved.append(profile) }
                if let text = ConnectionProfiles.encode(saved) { savedConnections = text }
                selected = profile.endpoint
                needsAuthorization.remove(profile.id)
            })
        }
        .confirmationDialog("Remove \(removing?.displayName ?? "connection")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                if let text = ConnectionProfiles.encode((ConnectionProfiles.decode(savedConnections) ?? []).filter { $0.id != removing.id }) { savedConnections = text }
                selected = "unix://"; self.removing = nil
            }
        } message: { Text("This removes the saved address. Access and any active connection remain available.") }
    }
    private func connecting(_ profile: ConnectionProfile) -> Bool { connections?.session(profile.id)?.workspace.isConnecting ?? workspace.isConnecting }
    private func connect(_ profile: ConnectionProfile) {
        guard !connecting(profile) else { return }
        error = nil
        Task {
            do {
                lastEndpoint = profile.endpoint
                let target: Workspace
                if let connections { target = try await connections.connect(profile) { try ConnectionClients.make(profile) }.workspace }
                else {
                    target = workspace
                    await target.connect(client: try ConnectionClients.make(profile), label: profile.endpoint)
                }
                if target.endpointLabel == profile.endpoint, let failure = target.connectionError {
                    error = failure
                    if failure.contains("Access refused") { needsAuthorization.insert(profile.id) }
                } else { needsAuthorization.remove(profile.id) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct ConnectionEditor: View {
    let profile: ConnectionProfile?
    let save: (ConnectionProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("computerName") private var computerName = ""
    @State private var name = ""
    @State private var address = ""
    @State private var kind = "remote"
    @State private var relays = ""
    @State private var directOnly = false
    @State private var tested: ConnectionProfile?
    @State private var error: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var peerID = ""
    @State private var loadingIdentity = false
    @State private var identityTask: Task<Void, Never>?
    @State private var enrollment = false
    @FocusState private var nameFocused: Bool

    private var placeholder: String { kind == "socket" ? "unix:///path/server.sock" : kind == "http" ? "https://server.example.com" : "Paste a discobox:// address" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(profile == nil ? "Add Connection" : "Edit Connection")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("Studio")).focused($nameFocused)
                    .accessibilityIdentifier("connection.name")
                Picker("Connect to", selection: $kind) {
                    Text("Remote computer").tag("remote")
                    Text("Custom local socket").tag("socket")
                    Text("HTTP/S server").tag("http")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind == "socket" ? "Socket address" : "Server address")
                    TextEditor(text: $address)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 80)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                        .overlay(alignment: .topLeading) {
                            if address.isEmpty {
                                Text(placeholder).font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11).padding(.vertical, 8).allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel(kind == "socket" ? "Socket address" : "Server address")
                        .accessibilityIdentifier("connection.address")
                }
                if kind == "remote" {
                    Text("Paste the Discobox address shared by the other computer.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Authorize this computer", isExpanded: $enrollment) {
                        Text("On the remote computer, enroll this app’s peer ID with Discobox. Each computer has its own identity.").font(.caption).foregroundStyle(.secondary)
                        TextField("This computer’s name", text: $computerName, prompt: Text(ComputerIdentity.systemName))
                        if loadingIdentity { ProgressView("Loading identity…").controlSize(.small) }
                        if peerID.isEmpty {
                            Button("Show My Peer ID") { loadIdentity() }.disabled(loadingIdentity)
                        } else {
                            Text(peerID).font(.caption.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("Copy Peer ID") { copy(peerID) }
                                Button("Copy Enrollment Command") { copy(ComputerIdentity.enrollmentCommand(peerID: peerID, name: computerName)) }
                            }
                        }
                    }
                }
                DisclosureGroup("Advanced") {
                    if kind == "remote" {
                        Toggle("Direct connections only", isOn: $directOnly)
                        Text("Requires an ?addr=IP:port hint. Relays and discovery are disabled.").font(.caption).foregroundStyle(.secondary)
                        TextField("HTTPS relay URLs", text: $relays, prompt: Text("Optional, comma-separated")).disabled(directOnly)
                    }
                    Text("Testing checks access without switching your active workspace.").font(.caption).foregroundStyle(.secondary)
                    if kind == "socket" { Text("Use unix:// for the default server on this computer.").font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).disabled(testing)
            if let tested { Label("Connection to \(tested.displayName) verified", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Save now and finish setup later. Testing is optional.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { testTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Test Connection") { test() }
                    .disabled(testing || loadingIdentity || fieldsEmpty)
                    .accessibilityIdentifier("connection.test")
                Button("Save") { saveConnection() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(fieldsEmpty)
                    .accessibilityIdentifier("connection.save")
            }
        }.padding(24).frame(width: 520, height: 580)
        .onAppear {
            if let profile {
                name = profile.displayName; address = profile.endpoint; relays = profile.relayURLs; directOnly = profile.directOnly ?? false
                kind = profile.isRemote ? "remote" : profile.endpoint.hasPrefix("unix:") ? "socket" : "http"
            }
            nameFocused = true
        }
        .onChange(of: address) { _, value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("unix:") { kind = "socket" }
            else if value.hasPrefix("http:") || value.hasPrefix("https:") { kind = "http" }
            else if value.hasPrefix("discobox:") || value.hasPrefix("iroh:") { kind = "remote" }
        }
        .onChange(of: draft) { _, _ in tested = nil; error = nil }
        .onDisappear { testTask?.cancel(); identityTask?.cancel() }
    }
    private var fieldsEmpty: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var draft: ConnectionProfile { .init(name: name, endpoint: address, relayURLs: kind == "remote" ? relays : "", directOnly: kind == "remote" && directOnly) }
    private func validatedProfile() throws -> ConnectionProfile {
        try ConnectionProfiles.validated(name: draft.name, endpoint: draft.endpoint, relayURLs: draft.relayURLs, directOnly: draft.directOnly ?? false)
    }
    private func saveConnection() {
        do { let profile = try validatedProfile(); testTask?.cancel(); save(profile); dismiss() }
        catch { self.error = error.localizedDescription }
    }
    private func test() {
        error = nil
        do {
            let profile = try validatedProfile()
            testing = true
            testTask = Task {
                defer { testing = false }
                do {
                    try await ConnectionProfiles.test(client: ConnectionClients.make(profile))
                    guard !Task.isCancelled else { return }
                    tested = profile
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    if profile.isRemote && error.localizedDescription.contains("Access refused") { enrollment = true; loadIdentity() }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func loadIdentity() {
        guard !loadingIdentity else { return }
        loadingIdentity = true
        identityTask = Task {
            defer { loadingIdentity = false }
            do {
                let id = try await IrohConnection.peerID(executable: CompanionLocation.executable, seed: IrohIdentity.seed())
                if !Task.isCancelled { peerID = id }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
