import SwiftUI
import DiscoboxCore

struct BulkBoxActionRequest: Identifiable {
    let id = UUID()
    let boxes: [Sandbox]
    let action: BoxAction
    let connection: UUID
    let computer: String
}

/// Shared by the sidebar and pool resources. Closing never cancels or retries
/// an already submitted action; background failures remain visible on the host.
struct BulkBoxActionSheet: View {
    let request: BulkBoxActionRequest
    var completed: ([String]) -> Void = { _ in }
    @Environment(ConnectionSession.self) private var workspace
    @Environment(TerminalStore.self) private var terminals: TerminalStore?
    @Environment(ServiceForwards.self) private var forwards: ServiceForwards?
    @Environment(DesktopWindows.self) private var desktops: DesktopWindows?
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var closed = false
    @State private var progress = 0
    @State private var result: BoxCommands.BulkActionResult?
    @State private var failure: String?

    var body: some View {
        StudioConfirmation(title: "\(request.action.title) \(request.boxes.count) boxes?", symbol: request.action.symbol,
            subtitle: request.computer) {
            VStack(alignment: .leading, spacing: 14) {
                Text(request.action.explanation).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(request.boxes) { box in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(box.displayName).fontWeight(.medium)
                                Text("Pool: " + (box.poolId ?? "Not reported")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: min(220, CGFloat(request.boxes.count) * 52)).studioCard()
                if working {
                    ProgressView("\(progress) of \(request.boxes.count) requests completed", value: Double(progress), total: Double(request.boxes.count))
                    Text("You can close this window while requests continue. Check the boxes before submitting another action.").font(.caption).foregroundStyle(.secondary)
                }
                if let result {
                    Text("\(request.action.title) accepted for \(result.accepted.count) of \(request.boxes.count) boxes.").font(.headline)
                    if !result.failures.isEmpty {
                        ScrollView {
                            Text(failureText(result)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }.frame(maxHeight: 130)
                    }
                }
                if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            }
        } footer: {
            HStack {
                Button(working ? "Close" : result != nil || failure != nil ? "Done" : "Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if result == nil && failure == nil {
                    Button("\(request.action.title) \(request.boxes.count) Boxes", action: submit)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(working || request.connection != workspace.connectionState.connectionID)
                        .accessibilityIdentifier("bulkAction.confirm")
                }
            }
        }.onDisappear { closed = true }
    }
    private func close() { closed = true; dismiss() }
    private func failureText(_ result: BoxCommands.BulkActionResult) -> String {
        result.failures.map { row in
            (request.boxes.first { $0.id == row.boxID }?.displayName ?? row.boxID) + ": " + row.message
        }.joined(separator: "\n")
    }
    private func submit() {
        working = true
        Task {
            defer { working = false }
            do {
                let response = try await workspace.commands.performBoxActions(request.action, boxIDs: request.boxes.map(\.id), connection: request.connection,
                    progress: { done, _ in progress = done }, beforeRequest: { id in
                        if [.stop, .archive, .upgrade, .repair].contains(request.action) {
                            terminals?.closeBox(id, connection: request.connection)
                            forwards?.close(box: id); desktops?.close(box: id)
                        }
                    }, onAccepted: { id in completed([id]) })
                result = response
                if closed, !response.failures.isEmpty, workspace.connectionState.connectionID == request.connection {
                    workspace.selection.commandError = failureText(response)
                }
            } catch {
                let message = error.localizedDescription + " Check the boxes before trying again. Nothing was retried."
                failure = message
                if closed, workspace.connectionState.connectionID == request.connection { workspace.selection.commandError = message }
            }
        }
    }
}
