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
    @Environment(ConnectionSession.self) private var workspace
    var body: some View {
        ForEach(BoxAction.allCases.filter { $0.isAvailable(for: box) }) { action in
            Button(role: action == .purge ? .destructive : nil) { choose(action) } label: {
                Label(action.title + "…", systemImage: action.symbol)
            }.disabled(workspace.pending.pendingBoxActions.contains(box.id))
        }
    }
}

struct BoxActionSheet: View {
    @Environment(Connections.self) private var connections: Connections?
    let request: BoxActionRequest
    @Environment(ConnectionSession.self) private var workspace
    @Environment(TerminalStore.self) private var terminals
    @Environment(ServiceForwards.self) private var forwards
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var failure: String?
    @State private var closed = false
    @State private var startedAt: Date?
    @FocusState private var fieldFocused: Bool
    private var computer: String? { connections?.sessions.first { $0 === workspace }?.profile.displayName }
    private var availabilityIssue: String? {
        guard workspace.connectionState.isConnected, request.connection == workspace.connectionState.connectionID else {
            return "This computer disconnected or reconnected. Cancel and choose the box again."
        }
        guard let box = workspace.inventory.sandboxes.first(where: { $0.id == request.box.id }), request.action.isAvailable(for: box) else {
            return "The box’s state changed. This action is no longer available."
        }
        if workspace.pending.pendingBoxActions.contains(box.id) { return "An action is already in progress for this box." }
        if workspace.pending.clearingPools.contains(box.poolId ?? "") { return "This pool is clearing its caches. Wait for cleanup to finish." }
        return nil
    }
    var body: some View {
        StudioConfirmation(title: "\(request.action.title) box", symbol: request.action.symbol,
                           subtitle: computer, destructive: request.action == .purge) {
            VStack(alignment: .leading, spacing: 18) {
                StudioConfirmationSubject(name: request.box.displayName)
                Text(request.action.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if request.action == .rename {
                    StudioConfirmationField(title: "Box name") {
                        TextField("Box name", text: $name).focused($fieldFocused)
                    }
                }
                if request.action == .purge {
                    StudioConfirmationField(title: "Type DELETE to permanently delete this box") {
                        TextField("DELETE", text: $confirmation).focused($fieldFocused)
                            .accessibilityIdentifier("boxAction.confirmation")
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if !working, let availabilityIssue { Text(availabilityIssue).foregroundStyle(.secondary) }
                if working, let startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(request.action.progressTitle).controlSize(.small)
                            if context.date.timeIntervalSince(startedAt) >= 10 {
                                Text("Still waiting for Discobox. You can close this window while the request continues. Check the box’s state before submitting it again.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } footer: {
            HStack {
                Button(working ? "Close" : "Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.action.title, role: request.action == .purge ? .destructive : nil) {
                    working = true; failure = nil; startedAt = Date()
                    Task {
                        do {
                            try await workspace.commands.performBoxAction(request.action, boxID: request.box.id, connection: request.connection, name: name, onAccepted: {
                                working = false
                                if !closed { close() }
                            }) {
                                if [.stop, .archive, .purge, .upgrade, .repair].contains(request.action) {
                                    terminals.closeBox(request.box.id, connection: request.connection)
                                    forwards.close(box: request.box.id)
                                }
                            }
                            if !closed {
                                working = false
                                failure = "The computer’s connection changed. Check the box’s current state."
                            }
                        } catch {
                            let message = request.action.title + " “" + request.box.displayName + "”: " + error.localizedDescription + " Check the box’s current state before trying again."
                            if !closed { failure = message }
                            else if workspace.connectionState.connectionID == request.connection { workspace.selection.commandError = message }
                            working = false
                        }
                    }
                }.buttonStyle(.borderedProminent).tint(request.action == .purge ? .red : DiscoboxAppearance.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("boxAction.confirm")
                    .disabled(working || availabilityIssue != nil || (request.action == .purge && confirmation != "DELETE") || (request.action == .rename && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 128)))
            }
        }
            .onAppear { name = request.box.displayName; fieldFocused = request.action == .rename || request.action == .purge }
            .onDisappear { closed = true }
            .interactiveDismissDisabled(working)
    }
    private func close() { closed = true; dismiss() }
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
    @Environment(ConnectionSession.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var working = false
    @State private var progress = 0
    @State private var error: String?
    @State private var result: BoxCommands.PurgeResult?
    @FocusState private var confirmationFocused: Bool
    private var computer: String? { connections?.sessions.first { $0 === workspace }?.profile.displayName }
    var body: some View {
        StudioConfirmation(title: "Purge \(request.boxes.count) archived boxes?", symbol: "trash", subtitle: computer, destructive: true) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Permanently delete these boxes, their workspaces, configuration, and secrets. This cannot be undone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                List(request.boxes) { box in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(box.displayName).fontWeight(.medium)
                        Text(box.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .frame(height: min(220, CGFloat(request.boxes.count) * 55 + 16))
                    .background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
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
                } else {
                    StudioConfirmationField(title: "Type DELETE to confirm permanent deletion") {
                        TextField("DELETE", text: $confirmation).focused($confirmationFocused).disabled(working)
                            .accessibilityIdentifier("bulkPurge.confirmation")
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if working { ProgressView("Purging \(progress) of \(request.boxes.count)…", value: Double(progress), total: Double(request.boxes.count)) }
                }
            }
        } footer: {
            if result != nil {
                HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            } else {
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                    Spacer()
                    Button("Purge \(request.boxes.count) Boxes", role: .destructive) {
                        working = true; error = nil
                        Task {
                            defer { working = false }
                            do {
                                let report = try await workspace.commands.purgeArchivedBoxes(request.boxes.map(\.id), connection: request.connection) { done, _ in progress = done }
                                completed(report.purged)
                                if report.failures.isEmpty { dismiss() } else { result = report }
                            } catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).tint(.red).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("bulkPurge.confirm")
                        .disabled(working || confirmation != "DELETE" || request.connection != workspace.connectionState.connectionID)
                }
            }
        }
            .onAppear { confirmationFocused = true }
            .interactiveDismissDisabled(working)
    }
}
