import SwiftUI
import DiscoboxCore

struct CredentialDetailsRequest: Identifiable {
    let id = UUID()
    let secret: JSONValue
    let connection: UUID
}

struct CredentialDetailsView: View {
    let request: CredentialDetailsRequest
    let saved: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(\.dismiss) private var dismiss
    @State private var maximum = ""
    @State private var host = ""
    @State private var reviewed = false
    @State private var busy = false
    @State private var error: String?
    @State private var completed = false
    private var secret: JSONValue { request.secret }
    private var valid: Bool { workspace.isConnected && workspace.connectionID == request.connection }
    private var payload: JSONValue? { try? CredentialLimits.payload(secret: secret, seconds: maximum, host: host) }
    var body: some View {
        StudioConfirmation(title: "Credential details", symbol: "key", subtitle: connections?.sessions.first { $0.workspace === workspace }?.profile.displayName, width: 640) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(secret["name"].string).font(.headline)
                    Text("Shared project credential · " + secret["type"].string).font(.caption).foregroundStyle(.secondary)
                    if CredentialLimits.isLegacy(secret) {
                        TextField("Allowed host (empty removes the host restriction)", text: $host)
                    } else {
                        RouteReview(routes: secret["routes"].array, title: "Allowed destinations")
                        Text("Destination routes are shown for review. Use the matching Discobox console to edit them.").font(.caption).foregroundStyle(.secondary)
                    }
                    if CredentialLimits.maximum(secret) != nil {
                        TextField("Maximum access lifetime · seconds", text: $maximum)
                        Text("Zero permits access without expiry. These are shared restrictions for this credential, not a decision on one box’s request.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("I reviewed this shared credential’s limits", isOn: $reviewed).toggleStyle(.checkbox)
                    } else { Text("This server does not report editable lifetime limits.").font(.callout).foregroundStyle(.secondary) }
                    if completed { Label("Shared limits saved", systemImage: "checkmark.circle") }
                    if !valid { Text("This computer reconnected. Reopen the credential details.").foregroundStyle(.orange) }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }.frame(height: 300).disabled(busy || completed)
        } footer: {
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if !completed {
                    Button("Save shared limits", action: save).buttonStyle(.borderedProminent)
                        .disabled(!valid || busy || !reviewed || payload == nil)
                }
            }
        }.onAppear {
            let limit = CredentialLimits.maximum(secret) ?? 0
            maximum = limit.isFinite && limit >= 0 && limit < Double(Int.max) ? String(Int(limit)) : ""
            host = secret["host"].string
        }.onChange(of: maximum) { reviewed = false }.onChange(of: host) { reviewed = false }
    }
    private func save() {
        guard valid, !busy, reviewed, let payload else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await workspace.operation(.updateSecretLimits, requestID: secret["id"].string, payload: payload)
                guard valid else { return }
                completed = true; saved()
            } catch { self.error = error.localizedDescription; reviewed = false }
        }
    }
}
