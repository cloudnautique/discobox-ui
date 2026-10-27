import SwiftUI
import AppKit
import DiscoboxCore

struct NewBoxSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var harnesses: [Harness] = []
    @State private var harness = ""
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
                Picker("Harness", selection: $harness) {
                    Text("Choose a harness").tag("")
                    ForEach(harnesses) { item in Text(item.name + (item.configured ? "" : " — not configured")).tag(item.id).disabled(!item.configured) }
                }
                TextField("Repository (optional)", text: $repository, prompt: Text("https://github.com/owner/repo or owner/repo"))
                    .textFieldStyle(.roundedBorder)
                Text("Starting prompt (optional)")
                TextEditor(text: $prompt).frame(height: 90).border(.quaternary)
                Text("Leave blank to start without a task.").font(.caption).foregroundStyle(.secondary)
            }.disabled(creating || loading)
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if loading { ProgressView("Loading harnesses…") }
            if !loading && harnesses.filter(\.configured).isEmpty { Text("No configured harnesses are available. Configure a harness in Discobox first.").foregroundStyle(.secondary) }
            if creating { ProgressView("Preparing source and creating your box…").controlSize(.small)
                Text("Repository delivery can take several minutes. This window stays open until it finishes.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Spacer()
                Button("Create Box") {
                    creating = true; error = nil
                    Task {
                        do { try await workspace.createBox(harness: harness, repository: repository.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt); dismiss() }
                        catch { self.error = error.localizedDescription }
                        creating = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(harness.isEmpty || creating || loading)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(creating)
        .task {
            do { harnesses = try await workspace.harnesses(); harness = harnesses.first(where: \.configured)?.id ?? "" }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct AuditView: View {
    let boxID: String
    var focusSearch = true
    @FocusState private var searchFocused: Bool
    @Environment(Workspace.self) private var workspace
    @State private var records: [AuditRecord] = []
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
                TextField("Search audit", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
            }.padding(12)
            if let error { Notice(text: error, symbol: "exclamationmark.triangle") }
            if !missing.isEmpty { Notice(text: "Unavailable trails: " + missing.joined(separator: "; "), symbol: "exclamationmark.triangle") }
            if !limited.isEmpty { Notice(text: "Recent-event limit reached: " + limited.joined(separator: ", ") + ". Earlier events may be missing.", symbol: "clock") }
            VSplitView {
                List(selection: $selected) {
                    ForEach(records.filter { (source == "All" || $0.source == source) && (search.isEmpty || $0.summary.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)) }) { record in
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
                Button(paging ? "Loading…" : "Load older") { loadOlder() }.disabled(paging || before.isEmpty)
                Spacer()
                if let lastRead { Text(lastRead, style: .time).font(.caption2) }
            }.foregroundStyle(.secondary).padding(10)
        }.onChange(of: selected) { recording = nil }
        .task(id: focusSearch) {
            if focusSearch { await Task.yield() }
            guard !Task.isCancelled else { return }
            searchFocused = focusSearch
        }
        .task(id: boxID) {
            records = []; missing = []; limited = []; selected = nil; lastRead = nil
            before = [:]; since = [:]; after = [:]
            while !Task.isCancelled {
                if following || lastRead == nil {
                    do {
                        let cursor: JSONValue? = lastRead == nil ? nil : .object(["since": .object(since.mapValues { .string($0) }), "after": .object(after.mapValues { .string($0) })])
                        let snapshot = try await workspace.auditSnapshot(box: boxID, cursor: cursor)
                        guard !Task.isCancelled else { return }
                        var merged = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                        for record in snapshot.records { merged[record.id] = record }
                        records = Array(merged.values.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order > $1.order }.prefix(50000))
                        if lastRead == nil { before = snapshot.before ?? [:] }
                        if merged.count > 50000 { error = "The view retains 50,000 events." }
                        since.merge(snapshot.since ?? [:]) { _, next in next }
                        after.merge(snapshot.after ?? [:]) { _, next in next }
                        missing = snapshot.missing; limited = snapshot.limited; error = nil; lastRead = Date()
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func loadOlder() {
        paging = true
        Task {
            defer { paging = false }
            do {
                let snapshot = try await workspace.auditSnapshot(box: boxID, cursor: .object(["before": .object(before.mapValues { .string($0) })]))
                guard !Task.isCancelled else { return }
                var merged = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                for record in snapshot.records { merged[record.id] = record }
                if merged.count == records.count { error = "No older rows returned. Timestamp-only trails cannot advance past a full page of equal timestamps." }
                if merged.count > 50000 { error = "The view retains 50,000 events. Narrow the source/time range in the CLI for a larger export." }
                records = Array(merged.values.sorted { $0.order > $1.order }.prefix(50000))
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
