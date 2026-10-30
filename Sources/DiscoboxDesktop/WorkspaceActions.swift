import SwiftUI
import AppKit
import DiscoboxCore

struct NewBoxSheet: View {
    @Environment(WorkspaceCommands.self) private var commands: WorkspaceCommands?
    @Environment(Workspace.self) private var initialWorkspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(ConnectionRuntimes.self) private var runtimes: ConnectionRuntimes?
    @State private var targetComputer = ""
    private var workspace: Workspace { connections?.session(targetComputer)?.workspace ?? initialWorkspace }
    @Environment(\.dismiss) private var dismiss
    private var harnesses: [Harness] { workspace.cachedHarnesses }
    @State private var harness = ""
    @State private var poolID = ""
    @State private var showResources = false
    @State private var repository = ""
    @State private var prompt = ""
    @State private var loading = true
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New box").font(.title2.bold())
            Text("Choose an agent harness and, optionally, a Git repository.").foregroundStyle(.secondary)
            Form {
                if let connections {
                    Picker("Computer", selection: $targetComputer) {
                        ForEach(connections.sessions.filter { $0.workspace.isConnected }) { host in Text(host.profile.displayName).tag(host.id) }
                    }
                }
                Picker("Pool", selection: $poolID) {
                    Text("Automatic placement").tag("")
                    ForEach(workspace.resources.pools) { pool in
                        Text(pool.name + (pool.id == workspace.resources.defaultPoolID ? " (default)" : "")).tag(pool.id)
                    }
                }
                Picker("Harness", selection: $harness) {
                    Text("Choose a harness").tag("")
                    ForEach(harnesses) { item in Text(item.name + (item.configured ? "" : " — not configured")).tag(item.id).disabled(!item.configured) }
                }
                TextField("Repository (optional)", text: $repository, prompt: Text("https://github.com/owner/repo or owner/repo"))
                    .textFieldStyle(.roundedBorder)
                Text("Starting prompt (optional)")
                TextEditor(text: $prompt).frame(height: 90).border(.quaternary)
                Text("Leave blank to start without a task.").font(.caption).foregroundStyle(.secondary)
            }.disabled(creating)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let destination = poolID.isEmpty ? workspace.resources.defaultPoolID : poolID
                let health = workspace.resources.health(destination, now: context.date)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pool resources").font(.headline)
                        Spacer()
                        if workspace.resources.isRefreshing { ProgressView().controlSize(.mini) }
                        Button("Manage Resources…") { showResources = true }.disabled(creating)
                    }
                    ResourceHealthNotice(health: health, reportedAt: workspace.resources.pools.first { $0.id == destination }?.reportedAt)
                    if let pool = workspace.resources.pools.first(where: { $0.id == destination }) {
                        HStack(spacing: 16) {
                            Text("Memory: " + ResourceValue.bytes(pool.memoryAvailable) + " available")
                            Text("CPU: " + ResourceValue.cpu(pool.totalCPU(boxes: workspace.sandboxes)) + " / " + ResourceValue.cpu(pool.cpuCapacity) + " cores")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = workspace.resources.error { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Text(PoolResourceHealth.cacheLimitation).font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if loading && harnesses.isEmpty { ProgressView("Loading harnesses…") }
            if !loading && harnesses.filter(\.configured).isEmpty { Text("No configured harnesses are available. Configure a harness in Discobox first.").foregroundStyle(.secondary) }
            if creating { ProgressView("Preparing source and creating your box…").controlSize(.small)
                Text("Repository delivery can take several minutes. This window stays open until it finishes.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Spacer()
                Button("Create Box") {
                    creating = true; error = nil
                    let target = workspace, hostID = targetComputer, generation = workspace.connectionID
                    let destination = poolID.isEmpty ? workspace.resources.defaultPoolID : poolID
                    Task {
                        do {
                            let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let connections {
                                try await connections.createBox(on: hostID, harness: harness, repository: repository, prompt: prompt, poolID: destination, connection: generation)
                            } else {
                                try await target.createBox(harness: harness, repository: repository, prompt: prompt, poolID: destination, connection: generation)
                            }
                            commands?.showCreateBox = false
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription }
                        creating = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("newBox.create")
                    .disabled(harness.isEmpty || creating || !harnesses.contains(where: { $0.id == harness && $0.configured }) || !workspace.resources.health(poolID.isEmpty ? workspace.resources.defaultPoolID : poolID).canCreate || workspace.clearingPools.contains(poolID.isEmpty ? workspace.resources.defaultPoolID ?? "" : poolID))
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(creating)
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
            }.padding(12)
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
                }.listStyle(.inset).frame(minWidth: 280)
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
