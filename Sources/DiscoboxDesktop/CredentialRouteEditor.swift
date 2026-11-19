import SwiftUI
import DiscoboxCore

/// Edits a draft. The parent confirms and saves the shared credential.
struct CredentialRouteEditor: View {
    let routes: [JSONValue]
    let accept: ([JSONValue]) -> Void
    @Environment(ConnectionSession.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var originalLines: [String] = []
    @State private var loaded = false
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        StudioConfirmation(title: "Edit credential routes", symbol: "network", width: 620) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter one Discobox route per line. Each box’s grant can narrow these routes further.")
                Text("Example route").font(.caption).foregroundStyle(.secondary)
                Text("POST api.example.test/projects/demo/issues/*/comments")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                TextEditor(text: $text).font(.body.monospaced()).frame(height: 180)
                    .accessibilityLabel("Shared credential routes")
                    .disabled(!loaded || checking)
                if loaded && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("With no routes, this credential cannot be sent to any destination.").foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        } footer: {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if checking || (!loaded && error == nil) { ProgressView().controlSize(.small) }
                Button("Use these routes") { checking = true }
                    .buttonStyle(.borderedProminent).disabled(!loaded || checking)
                    .accessibilityIdentifier("credential.acceptRoutes")
            }
        }.task {
            do {
                let preview = try await workspace.credentials.previewRoutes(routes)
                try Task.checkCancellation()
                text = preview.lines.joined(separator: "\n")
                originalLines = preview.lines
                loaded = true
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }.task(id: checking) {
            guard checking else { return }
            do {
                let lines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let preview = try await workspace.credentials.previewRoutes(lines.map(JSONValue.string))
                try Task.checkCancellation()
                accept(preview.lines == originalLines ? routes : preview.routes)
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; checking = false }
            }
        }
    }
}
