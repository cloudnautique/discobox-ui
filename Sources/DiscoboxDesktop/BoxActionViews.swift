import SwiftUI
import DiscoboxCore

struct BoxActionRequest: Identifiable {
    let id = UUID()
    let box: Sandbox
    let action: BoxAction
    let connection: UUID
}

struct BoxActionMenu: View {
    let box: Sandbox
    let choose: (BoxAction) -> Void
    @Environment(Workspace.self) private var workspace
    var body: some View {
        ForEach(BoxAction.allCases.filter { $0.isAvailable(for: box) }) { action in
            Button(role: action == .purge ? .destructive : nil) { choose(action) } label: {
                Label(action.title + "…", systemImage: action.symbol)
            }.disabled(workspace.pendingBoxActions.contains(box.id))
        }
    }
}

struct BoxActionSheet: View {
    @Environment(Connections.self) private var connections: Connections?
    let request: BoxActionRequest
    @Environment(Workspace.self) private var workspace
    @Environment(TerminalStore.self) private var terminals
    @Environment(ServiceForwards.self) private var forwards
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("\(request.action.title) box", systemImage: request.action.symbol).font(.title2.bold())
            Text(request.box.displayName).font(.headline).textSelection(.enabled)
            if let host = connections?.sessions.first(where: { $0.workspace === workspace }) { Text(host.profile.displayName).font(.callout).foregroundStyle(.secondary) }
            Text(request.action.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if request.action == .rename {
                TextField("Box name", text: $name).textFieldStyle(.roundedBorder)
            }
            if request.action == .purge {
                TextField("Type DELETE to permanently delete", text: $confirmation).textFieldStyle(.roundedBorder)
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(working ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(request.action.title, role: request.action == .purge ? .destructive : nil) {
                    working = true; failure = nil
                    Task {
                        do {
                            try await workspace.performBoxAction(request.action, boxID: request.box.id, connection: request.connection, name: name) {
                                if [.stop, .archive, .purge, .upgrade, .repair].contains(request.action) {
                                    terminals.closeBox(request.box.id, connection: request.connection)
                                    forwards.close(box: request.box.id)
                                }
                            }
                            dismiss()
                        } catch {
                            failure = error.localizedDescription + " Check the box’s current state before trying again."
                            working = false
                        }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(working || request.connection != workspace.connectionID || (request.action == .purge && confirmation != "DELETE") || (request.action == .rename && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 128)))
            }
        }.padding(24).frame(width: 440)
            .onAppear { name = request.box.displayName }
            .interactiveDismissDisabled(working)
    }
}

struct BulkPurgeRequest: Identifiable {
    let id = UUID()
    let boxes: [Sandbox]
    let connection: UUID
}

struct BulkPurgeSheet: View {
    @Environment(Connections.self) private var connections: Connections?
    let request: BulkPurgeRequest
    let completed: ([String]) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var working = false
    @State private var progress = 0
    @State private var error: String?
    @State private var result: Workspace.PurgeResult?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Purge \(request.boxes.count) archived boxes?").font(.title2.weight(.semibold))
            if let host = connections?.sessions.first(where: { $0.workspace === workspace }) { Text(host.profile.displayName).font(.callout).foregroundStyle(.secondary) }
            Text("Permanently delete these boxes, their workspaces, configuration, and secrets. This cannot be undone.")
            List(request.boxes) { box in
                VStack(alignment: .leading, spacing: 4) {
                    Text(box.displayName).fontWeight(.medium)
                    Text(box.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }.padding(.vertical, 3)
            }.frame(height: min(220, CGFloat(request.boxes.count) * 55 + 16))
            if let result {
                Text("Purged \(result.purged.count) of \(request.boxes.count) boxes.").font(.headline)
                if !result.failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(result.failures, id: \.boxID) { failure in
                                Text((request.boxes.first { $0.id == failure.boxID }?.displayName ?? failure.boxID) + ": " + failure.message)
                                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                    }.frame(maxHeight: 140)
                    Text("No failed request was retried. Refresh Archived to check the remaining boxes.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                TextField("Type DELETE to confirm", text: $confirmation).textFieldStyle(.roundedBorder).disabled(working)
                if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if working { ProgressView("Purging \(progress) of \(request.boxes.count)…", value: Double(progress), total: Double(request.boxes.count)) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                    Spacer()
                    Button("Purge \(request.boxes.count) Boxes", role: .destructive) {
                        working = true; error = nil
                        Task {
                            defer { working = false }
                            do {
                                let report = try await workspace.purgeArchivedBoxes(request.boxes.map(\.id), connection: request.connection) { done, _ in progress = done }
                                completed(report.purged)
                                if report.failures.isEmpty { dismiss() } else { result = report }
                            } catch { self.error = error.localizedDescription }
                        }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(working || confirmation != "DELETE" || request.connection != workspace.connectionID)
                }
            }
        }.padding(24).frame(width: 480)
            .interactiveDismissDisabled(working)
    }
}
