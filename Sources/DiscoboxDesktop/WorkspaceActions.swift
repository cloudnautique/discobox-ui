import SwiftUI
import AppKit
import DiscoboxCore

struct NewBoxSheet: View {
    @Environment(WorkspaceCommands.self) private var commands: WorkspaceCommands?
    @Environment(Workspace.self) private var initialWorkspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(ConnectionRuntimes.self) private var runtimes: ConnectionRuntimes?
    @State private var targetComputer = ""
    init(repository: String = "", computer: String? = nil) {
        _repository = State(initialValue: repository)
        _targetComputer = State(initialValue: computer ?? "")
    }
    private var currentRepository: RepositoryChoice? { workspace.selectedBox.flatMap(RepositoryChoice.init(box:)) }
    private var recentRepositories: [RepositoryChoice] { RepositoryChoice.recent(in: workspace.sandboxes).filter { $0.id != currentRepository?.id } }
    private var workspace: Workspace { connections?.session(targetComputer)?.workspace ?? initialWorkspace }
    @Environment(\.dismiss) private var dismiss
    private var harnesses: [Harness] { workspace.cachedHarnesses }
    @State private var harness = ""
    @State private var poolID = ""
    @State private var showResources = false
    @State private var repository = ""
    @State private var prompt = ""
    @State private var credentialDrafts: [LaunchCredentialDraft] = []
    @State private var loading = true
    @State private var creating = false
    @State private var error: String?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case repository, prompt }
    private var credentialError: String? {
        do { _ = try LaunchCredential.payload(credentialDrafts.map(\.credential)); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioDialogHeader(title: "New box", symbol: "shippingbox", subtitle: "Create a workspace for your agent.", shortcut: commands?.appShortcuts[.newBox])
                .padding(24)
            Divider().overlay(DiscoboxAppearance.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DESTINATION & AGENT").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            if let connections {
                                StudioDestinationRow(title: "Computer", symbol: "desktopcomputer") {
                                    StudioMenuPicker(title: "Computer", selection: $targetComputer, options:
                                        connections.sessions.filter { $0.workspace.isConnected }.map { .init(id: $0.id, title: $0.profile.displayName) })
                                }
                                Divider().padding(.leading, 38)
                            }
                            StudioDestinationRow(title: "Pool", symbol: "server.rack") {
                                StudioMenuPicker(title: "Pool", selection: $poolID, options:
                                    [.init(id: "", title: "Automatic placement")] + workspace.resources.pools.map { .init(id: $0.id, title: $0.name) })
                            }
                            Divider().padding(.leading, 38)
                            StudioDestinationRow(title: "Harness", symbol: "sparkles") {
                                StudioMenuPicker(title: "Harness", selection: $harness, options:
                                    [.init(id: "", title: "Choose a harness")] + harnesses.map { .init(id: $0.id, title: $0.name + ($0.configured ? "" : " — not configured"), enabled: $0.configured) })
                                Button("Manage…") {
                                    if let selected = harnesses.first(where: { $0.id == harness }) {
                                        HarnessSetupWindows.shared.open(selected, workspace: workspace)
                                    }
                                }.font(.caption).buttonStyle(.plain).foregroundStyle(DiscoboxAppearance.accent)
                                    .disabled(harness.isEmpty || workspace.isDemo)
                                    .help("Manage this harness on the chosen computer")
                            }
                        }
                        .background(DiscoboxAppearance.chrome, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        StudioFieldLabel(title: "Repository")
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                            TextField("Repository", text: $repository, prompt: Text("owner/repository or Git URL"))
                                .textFieldStyle(.plain).focused($focusedField, equals: .repository)
                                .accessibilityIdentifier("newBox.repository")
                            Menu {
                                if let currentRepository {
                                    Section("Current repository") { repositoryButton(currentRepository) }
                                }
                                if !recentRepositories.isEmpty {
                                    Section("Recent repositories on this computer") {
                                        ForEach(recentRepositories) { choice in repositoryButton(choice) }
                                    }
                                }
                                if currentRepository == nil && recentRepositories.isEmpty {
                                    Text("No recent repositories on this computer")
                                }
                                Divider()
                                Button("No repository") { repository = ""; focusedField = .prompt }
                            } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                                .menuStyle(.borderlessButton).fixedSize().help("Choose a recent repository")
                                .accessibilityLabel("Recent repositories").accessibilityIdentifier("newBox.repositories")
                        }
                        .padding(12).background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focusedField == .repository ? DiscoboxAppearance.accent : DiscoboxAppearance.border, lineWidth: focusedField == .repository ? 1 : 0.5))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        StudioFieldLabel(title: "Starting prompt")
                        TextEditor(text: $prompt).font(.system(size: 12))
                            .scrollContentBackground(.hidden).focused($focusedField, equals: .prompt)
                            .padding(8).frame(height: 100)
                            .background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topLeading) {
                                if prompt.isEmpty {
                                    Text("What would you like the agent to work on?").font(.system(size: 12)).foregroundStyle(.tertiary)
                                        .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focusedField == .prompt ? DiscoboxAppearance.accent : DiscoboxAppearance.border, lineWidth: focusedField == .prompt ? 1 : 0.5))
                    }
                    NewBoxCredentialsSection(drafts: $credentialDrafts)
                    if let credentialError { Text(credentialError).font(.system(size: 11)).foregroundStyle(.orange) }
                    NewBoxResourceSummary(poolID: poolID, creating: creating, manage: { showResources = true })
                        .environment(workspace)
                    if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if loading && harnesses.isEmpty { ProgressView("Loading harnesses…").controlSize(.small) }
                    if !loading && harnesses.filter(\.configured).isEmpty {
                        Text("No configured harnesses are available. Configure a harness in Settings → Harnesses.").font(.callout).foregroundStyle(.secondary)
                    }
                    if creating {
                        ProgressView("Preparing source and creating your box…").controlSize(.small)
                        Text("Repository delivery can take several minutes. This window stays open until it finishes.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24).disabled(creating)
            }.frame(maxHeight: 580)
            Divider().overlay(DiscoboxAppearance.border)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Spacer()
                Button("Create Box", action: create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("newBox.create")
                    .disabled(credentialError != nil)
                    .disabled(harness.isEmpty || creating || !harnesses.contains(where: { $0.id == harness && $0.configured }) || !workspace.resources.health(poolID.isEmpty ? workspace.resources.defaultPoolID : poolID).canCreate || workspace.clearingPools.contains(poolID.isEmpty ? workspace.resources.defaultPoolID ?? "" : poolID))
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16).background(DiscoboxAppearance.chrome)
        }
        .frame(width: 560).background(DiscoboxAppearance.surface).tint(DiscoboxAppearance.accent)
        .interactiveDismissDisabled(creating)
        .onChange(of: workspace.connectionID) { _, _ in credentialDrafts.removeAll() }
        .onDisappear { credentialDrafts.removeAll() }
        .onAppear { focusedField = repository.isEmpty ? .repository : .prompt }
        .sheet(isPresented: $showResources) {
            if let host = connections?.session(targetComputer), let runtimes {
                PoolResourcesView(computer: host.profile.displayName, initialPoolID: poolID.isEmpty ? workspace.resources.defaultPoolID : poolID)
                    .environment(host.workspace)
                    .environment(runtimes.runtime(host.id).terminals)
                    .environment(runtimes.runtime(host.id).forwards)
                    .environment(runtimes.runtime(host.id).desktops)
            } else {
                PoolResourcesView(computer: workspace.endpointLabel, initialPoolID: poolID.isEmpty ? workspace.resources.defaultPoolID : poolID).environment(workspace)
            }
        }
        .onAppear { if targetComputer.isEmpty { targetComputer = connections?.suggestedCreationComputerID ?? "" } }
        .task(id: workspace.connectionID) {
            let target = workspace, generation = workspace.connectionID
            poolID = ""
            await target.refreshResources()
            guard !Task.isCancelled, workspace === target, generation == target.connectionID else { return }
            if poolID.isEmpty { poolID = target.resources.defaultPoolID ?? "" }
        }
        .task(id: workspace.connectionID) {
            let target = workspace, generation = workspace.connectionID
            error = nil
            harness = harnesses.first(where: \.configured)?.id ?? ""
            loading = harnesses.isEmpty
            do {
                let refreshed = try await target.harnesses()
                guard !Task.isCancelled, workspace === target, target.connectionID == generation else { return }
                if !refreshed.contains(where: { $0.id == harness && $0.configured }) { harness = refreshed.first(where: \.configured)?.id ?? "" }
            }
            catch {
                guard !Task.isCancelled, workspace === target, target.connectionID == generation else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func repositoryButton(_ choice: RepositoryChoice) -> some View {
        Button { repository = choice.source; focusedField = .prompt } label: {
            if repository == choice.source { Label(choice.title, systemImage: "checkmark") }
            else { Text(choice.title) }
        }.help(choice.source)
    }

    private func create() {
        creating = true; error = nil
        let target = workspace, hostID = targetComputer, generation = workspace.connectionID
        let destination = poolID.isEmpty ? workspace.resources.defaultPoolID : poolID
        let credentials = credentialDrafts.map(\.credential)
        let harness = harness, prompt = prompt
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if let connections {
                    try await connections.createBox(on: hostID, harness: harness, repository: repository, prompt: prompt, poolID: destination, connection: generation, credentials: credentials)
                } else {
                    try await target.createBox(harness: harness, repository: repository, prompt: prompt, poolID: destination, connection: generation, credentials: credentials)
                }
                credentialDrafts.removeAll()
                commands?.showCreateBox = false
                dismiss()
            }
            catch { self.error = error.localizedDescription }
            creating = false
        }
    }

}

/// Summarizes cached reports without adding resource reads to the creation flow.
private struct NewBoxResourceSummary: View {
    @Environment(Workspace.self) private var workspace
    let poolID: String
    let creating: Bool
    let manage: () -> Void
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let destination = poolID.isEmpty ? workspace.resources.defaultPoolID : poolID
            let pool = workspace.resources.pools.first { $0.id == destination }
            let health = workspace.resources.health(destination, now: context.date)
            let warning = health.level == .warning || health.level == .blocked
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: warning ? "exclamationmark.triangle" : "internaldrive")
                        .foregroundStyle(warning ? Color.orange : .secondary)
                    Text(summary(health, pool: pool)).font(.system(size: 11))
                    Spacer(minLength: 8)
                    if workspace.resources.isRefreshing { ProgressView().controlSize(.mini) }
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 4) {
                            Text("Details")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(DiscoboxAppearance.accent)
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                }
                // Warnings remain visible even when the optional details are closed.
                if warning {
                    ResourceHealthNotice(health: health).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                if let error = workspace.resources.error { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        if let pool {
                            let memory = ResourceValue.bytes(pool.memoryAvailable)
                            let cpuUsage = ResourceValue.cpu(pool.totalCPU(boxes: workspace.sandboxes))
                            let cpuCapacity = ResourceValue.cpu(pool.cpuCapacity)
                            let details: String = "Memory: \(memory) available · CPU: \(cpuUsage) / \(cpuCapacity) cores"
                            Text(details)
                            if let reportedAt = pool.reportedAt { Text("Reported \(reportedAt, style: .relative) ago") }
                        }
                        Text(PoolResourceHealth.cacheLimitation)
                        Button("Manage Resources…", action: manage).disabled(creating)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func summary(_ health: PoolResourceHealth, pool: ResourcePool?) -> String {
        if health.level == .healthy, let available = pool?.dataAvailable {
            return ResourceValue.bytes(available) + " data disk available"
        }
        switch health.level {
        case .warning: return "Pool resources need attention"
        case .blocked: return "Pool cannot accept a new box"
        case .stale: return "Resource measurements are out of date"
        default: return "Resource availability is unverified"
        }
    }
}

struct AuditView: View {
    let boxID: String
    var focusSearch = true
    @Environment(Workspace.self) private var workspace
    @State private var records: [AuditRecord] = []
    @State private var filteredRecords: [AuditRecord] = []
    @State private var buffer = AuditBuffer()
    @State private var recordsVersion = 0
    @State private var retentionLimited = false
    @State private var historyGeneration = UUID()
    private struct SearchKey: Equatable {
        let generation: UUID
        let version: Int
        let source: String
        let query: String
    }
    private var searchKey: SearchKey { .init(generation: historyGeneration, version: recordsVersion, source: source, query: search) }
    @State private var missing: [String] = []
    @State private var limited: [String] = []
    @State private var error: String?
    @State private var source = "All"
    @State private var search = ""
    @State private var following = true
    @State private var selected: String?
    @State private var lastRead: Date?
    @State private var before: [String: String] = [:]
    @State private var since: [String: String] = [:]
    @State private var after: [String: String] = [:]
    @State private var paging = false
    @State private var recording: String?
    @State private var recordingBusy = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                Picker("Source", selection: $source) {
                    ForEach(["All", "HTTP", "Credentials", "Refresh", "Hooks", "Execs"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 180)
                Spacer()
                Toggle("Follow", isOn: $following).toggleStyle(.switch).controlSize(.small)
                }
                AuditSearchField(text: $search, focusRequested: focusSearch).frame(height: 22)
            }.padding(12).background(DiscoboxAppearance.chrome)
            if let error { Notice(text: error, symbol: "exclamationmark.triangle") }
            if !missing.isEmpty { Notice(text: "Unavailable trails: " + missing.joined(separator: "; "), symbol: "exclamationmark.triangle") }
            if !limited.isEmpty { Notice(text: "Recent-event limit reached: " + limited.joined(separator: ", ") + ". Earlier events may be missing.", symbol: "clock") }
            if retentionLimited { Notice(text: "Audit history reached its 32 MiB or 50,000-event limit. Oldest events are removed as new events arrive.", symbol: "clock") }
            VSplitView {
                List(selection: $selected) {
                    ForEach(filteredRecords) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(record.source).font(.caption.weight(.semibold)); Spacer(); Text(record.time).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                            Text(record.summary).font(.callout).lineLimit(3)
                        }.padding(.vertical, 5).tag(record.id)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).background(DiscoboxAppearance.canvas).frame(minWidth: 280)
                if let record = records.first(where: { $0.id == selected }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(record.summary).font(.headline)
                            if record.source == "HTTP" {
                                HStack {
                                    Button("Request body") { readBody(record, part: "request") }
                                    Button("Response body") { readBody(record, part: "response") }
                                    Menu("Export") {
                                        Button("Request body…") { exportBody(record, part: "request") }
                                        Button("Response body…") { exportBody(record, part: "response") }
                                        Button("Upgraded stream…") { exportBody(record, part: "stream") }
                                    }
                                }.disabled(recordingBusy)
                                if recordingBusy { ProgressView().controlSize(.small) }
                                if let recording { Text(recording).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            }
                            Text(record.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.frame(minHeight: 100)
                        .background(InitialSplitFraction(fraction: 2.0 / 3.0))
                }
            }.overlay {
                if records.isEmpty && error == nil { ContentUnavailableView(lastRead == nil ? "Reading audit…" : "No audit events", systemImage: "list.bullet.rectangle") }
            }
            HStack {
                Text("\(records.count) retained events").font(.caption2)
                Button(paging ? "Loading…" : "Load older") { loadOlder() }.disabled(paging || before.isEmpty || retentionLimited)
                Spacer()
                if let lastRead { Text(lastRead, style: .time).font(.caption2) }
            }.foregroundStyle(.secondary).padding(10)
        }.onChange(of: selected) { recording = nil }
        .background(DiscoboxAppearance.canvas).tint(DiscoboxAppearance.accent)
        .task(id: searchKey) {
            let key = searchKey, input = records
            do {
                if !key.query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                let work = Task.detached(priority: .userInitiated) {
                    try AuditBuffer.filter(input, source: key.source, query: key.query)
                }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, key == searchKey else { return }
                filteredRecords = result
            } catch is CancellationError { return }
            catch { return }
        }
        .task(id: boxID) {
            buffer = AuditBuffer(); recordsVersion = 0; retentionLimited = false
            historyGeneration = UUID(); filteredRecords = []
            records = []; missing = []; limited = []; selected = nil; lastRead = nil
            before = [:]; since = [:]; after = [:]
            while !Task.isCancelled {
                if following || lastRead == nil {
                    do {
                        let cursor: JSONValue? = lastRead == nil ? nil : .object(["since": .object(since.mapValues { .string($0) }), "after": .object(after.mapValues { .string($0) })])
                        let snapshot = try await workspace.auditSnapshot(box: boxID, cursor: cursor)
                        guard !Task.isCancelled else { return }
                        let update = await buffer.merge(snapshot.records)
                        guard !Task.isCancelled else { return }
                        apply(update)
                        if lastRead == nil { before = snapshot.before ?? [:] }
                        since.merge(snapshot.since ?? [:]) { _, next in next }
                        after.merge(snapshot.after ?? [:]) { _, next in next }
                        missing = snapshot.missing; limited = snapshot.limited; error = nil; lastRead = Date()
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func apply(_ update: AuditBuffer.Snapshot) {
        guard update.version >= recordsVersion else { return }
        retentionLimited = update.limited
        if update.version != recordsVersion {
            records = update.records
            recordsVersion = update.version
            if let selected, !records.contains(where: { $0.id == selected }) { self.selected = nil }
        }
    }
    private func loadOlder() {
        paging = true
        let generation = historyGeneration, target = buffer
        Task {
            defer { paging = false }
            do {
                let snapshot = try await workspace.auditSnapshot(box: boxID, cursor: .object(["before": .object(before.mapValues { .string($0) })]))
                guard !Task.isCancelled, generation == historyGeneration else { return }
                let previousVersion = recordsVersion
                let update = await target.merge(snapshot.records)
                guard !Task.isCancelled, generation == historyGeneration else { return }
                apply(update)
                if update.version == previousVersion && !update.limited { error = "No older rows returned. Timestamp-only trails cannot advance past a full page of equal timestamps." }
                before.merge(snapshot.before ?? [:]) { _, next in next }
                missing = snapshot.missing
            } catch { self.error = error.localizedDescription }
        }
    }
    private func exportBody(_ record: AuditRecord, part: String) {
        let pieces = record.id.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count >= 3 else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = String(pieces[2]) + "-" + part + ".bin"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            recordingBusy = true
            Task {
                defer { recordingBusy = false }
                do {
                    let result = try await workspace.operation(.auditBody, requestID: String(pieces[2]), kind: String(pieces[1]), action: part, localPath: url.path)
                    recording = "Exported \(Int(result["bytes"].number ?? 0)) bytes." + (result["recordingTruncatedFrom"].string.isEmpty ? "" : " The pool retained only part of this recording (original: " + result["recordingTruncatedFrom"].string + " bytes).")
                } catch { recording = error.localizedDescription }
            }
        }
    }
    private func readBody(_ record: AuditRecord, part: String) {
        let pieces = record.id.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count >= 3 else { return }
        recordingBusy = true; recording = nil
        Task {
            defer { recordingBusy = false }
            do {
                let result = try await workspace.operation(.auditBody, requestID: String(pieces[2]), kind: String(pieces[1]), action: part)
                guard selected == record.id else { return }
                recording = result["text"].string + (result["truncated"] == .bool(true) ? "\n[Preview limited to 1 MiB]" : "") + (result["recordingTruncatedFrom"].string.isEmpty ? "" : "\n[Pool recording was truncated from " + result["recordingTruncatedFrom"].string + " bytes]")
            } catch { recording = error.localizedDescription }
        }
    }

}

/// Focus only after the native search field is attached to its window. A
/// SwiftUI focus-state update can otherwise precede the retained terminal's
/// reparenting when returning to Audit from a shell tab.
private struct AuditSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequested: Bool
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Search audit"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("audit.search")
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        let changed = field.focusRequested != focusRequested
        field.focusRequested = focusRequested
        if changed && focusRequested { field.requestFocus() }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
    final class Field: NSSearchField {
        var focusRequested = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if focusRequested { requestFocus() } }
        func requestFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRequested, let window = self.window, window.isKeyWindow else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
