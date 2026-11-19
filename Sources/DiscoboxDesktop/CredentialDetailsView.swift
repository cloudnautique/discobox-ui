import SwiftUI
import DiscoboxCore

struct CredentialDetailsRequest: Identifiable {
    let id = UUID()
    let secret: JSONValue
    let connection: UUID
}

struct CredentialDetailsView: View {
    let request: CredentialDetailsRequest
    let saved: (JSONValue) -> Void
    @Environment(ConnectionSession.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(\.dismiss) private var dismiss
    @State private var maximum = ""
    @State private var host = ""
    @State private var editedRoutes: [JSONValue]?
    @State private var editingRoutes = false
    @State private var pendingSave: CredentialSaveReview?
    @State private var busy = false
    @State private var error: String?
    @State private var verifiedSecret: JSONValue?
    private var completed: Bool { verifiedSecret != nil }
    private var secret: JSONValue { request.secret }
    private var valid: Bool { workspace.connectionState.isConnected && workspace.connectionState.connectionID == request.connection }
    private var routes: [JSONValue] { (verifiedSecret?["routes"].array) ?? editedRoutes ?? secret["routes"].array }
    private var draft: CredentialSaveReview? {
        guard let payload = try? CredentialLimits.payload(secret: secret, seconds: maximum, host: host, routes: editedRoutes) else { return nil }
        return CredentialSaveReview(payload: payload)
    }
    init(request: CredentialDetailsRequest, saved: @escaping (JSONValue) -> Void) {
        self.request = request
        self.saved = saved
        let seconds = CredentialLimits.maximum(request.secret).flatMap(Int.init(exactly:))
        _maximum = State(initialValue: seconds.map(String.init) ?? "")
        _host = State(initialValue: request.secret["host"].string)
    }
    var body: some View {
        StudioConfirmation(title: "Credential details", symbol: "key", subtitle: connections?.sessions.first { $0 === workspace }?.profile.displayName, width: 640) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(secret["name"].string).font(.headline)
                    Text("Shared project credential · " + secret["type"].string).font(.caption).foregroundStyle(.secondary)
                    if CredentialLimits.isLegacy(secret) {
                        TextField("Allowed host (empty removes the host restriction)", text: $host)
                    } else {
                        HStack {
                            Text("Shared credential routes").font(.headline)
                            Spacer()
                            Button("Edit routes…") { editingRoutes = true }
                                .disabled(!valid || secret["maxBindingTTLSeconds"].number == nil)
                        }
                        Text("These routes limit every box using this credential. Each box’s own grant and any parent restrictions also apply.").font(.caption).foregroundStyle(.secondary)
                        RouteReview(routes: routes, title: "Destinations")
                        ForEach(Array(secret["routeConstraints"].array.enumerated()), id: \.offset) { index, limit in
                            RouteReview(routes: limit.array, title: "Additional harness restriction \(index + 1)")
                        }
                    }
                    if CredentialLimits.maximum(secret) != nil {
                        StudioConfirmationField(title: "Maximum access lifetime · seconds") {
                            TextField("Seconds", text: $maximum).accessibilityIdentifier("credential.maximumLifetime")
                        }
                        Text("This limit applies to new grants. Existing grants keep their expiry. Zero permits a grant without expiry.")
                            .font(.caption).foregroundStyle(.secondary)
                        if (try? CredentialLimits.lifetimeSeconds(maximum)) == nil {
                            Text("Enter a whole number of seconds, zero or greater.").font(.caption).foregroundStyle(.orange)
                        }
                    } else { Text("This server does not report editable lifetime limits.").font(.callout).foregroundStyle(.secondary) }
                    if completed, let verifiedSecret, let limit = CredentialLimits.maximum(verifiedSecret) {
                        Label("Shared limits verified · " + (limit == 0 ? "No expiry limit" : ApprovalDuration.label(limit)), systemImage: "checkmark.circle")
                            .accessibilityIdentifier("credential.savedLifetime")
                    }
                    if !valid { Text("This computer reconnected. Reopen the credential details.").foregroundStyle(.orange) }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }.frame(height: 350).disabled(busy || completed)
        } footer: {
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if !completed {
                    Button("Save") { pendingSave = draft }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(!valid || busy || draft == nil)
                }
            }
        }.interactiveDismissDisabled(busy)
        .sheet(isPresented: $editingRoutes) {
            CredentialRouteEditor(routes: routes) { editedRoutes = $0 == secret["routes"].array ? nil : $0 }
        }
        .sheet(item: $pendingSave) { review in
            StudioConfirmation(title: "Save credential changes?", symbol: "key", subtitle: secret["name"].string) {
                if review.newRoutes != nil {
                    ScrollView { review.summary }.frame(height: 280)
                } else {
                    review.summary
                }
            } footer: {
                HStack {
                    Button("Cancel") { pendingSave = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Confirm save") { save(review) }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(!valid || busy)
                }
            }
        }.onChange(of: valid) { if !valid { pendingSave = nil; editingRoutes = false } }
    }
    private func save(_ review: CredentialSaveReview) {
        guard valid, !busy, !completed, pendingSave?.id == review.id else { return }
        pendingSave = nil
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                guard valid else { return }
                let confirmed = try await workspace.credentials.updateLimits(id: secret["id"].string, payload: review.payload)
                guard valid else { return }
                guard confirmed["id"] == secret["id"], CredentialLimits.maximum(confirmed) == review.maximum else {
                    throw DiscoboxError("Discobox did not confirm the saved lifetime. Reopen the credential details before trying again.")
                }
                verifiedSecret = confirmed
                saved(confirmed)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct CredentialSaveReview: Identifiable {
    let id = UUID()
    let payload: JSONValue
    let maximum: Double
    let previousMaximum: Double
    let newHost: String?
    let previousHost: String
    let newRoutes: [JSONValue]?
    let previousRoutes: [JSONValue]

    init?(payload: JSONValue) {
        let original = payload["expectedSecret"], limits = payload["limits"]
        guard let previous = CredentialLimits.maximum(original) else { return nil }
        self.payload = payload
        previousMaximum = previous
        maximum = CredentialLimits.maximum(limits) ?? previous
        previousHost = original["host"].string
        if case .string(let host) = limits["host"], host.caseInsensitiveCompare(previousHost) != .orderedSame {
            newHost = host
        } else { newHost = nil }
        previousRoutes = original["routes"].array
        if case .array(let routes) = limits["routes"], routes != previousRoutes {
            newRoutes = routes
        } else { newRoutes = nil }
        guard maximum != previous || newHost != nil || newRoutes != nil else { return nil }
    }

    private func lifetime(_ value: Double) -> String {
        value == 0 ? "No expiry limit" : ApprovalDuration.label(value)
    }
    var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if maximum != previousMaximum {
                Text("Maximum grant lifetime").font(.headline)
                Text("\(lifetime(previousMaximum)) → \(lifetime(maximum))")
                Text("Existing grants keep their expiry.").font(.caption).foregroundStyle(.secondary)
            }
            if let newHost {
                Text("Allowed host").font(.headline)
                Text("\(previousHost.isEmpty ? "Any host" : previousHost) → \(newHost.isEmpty ? "Any host" : newHost)")
            }
            if let newRoutes {
                Text("Shared routes").font(.headline)
                let changes = newRoutes.difference(from: previousRoutes)
                let removed = changes.removals.compactMap { change -> JSONValue? in
                    if case .remove(_, let route, _) = change { return route }
                    return nil
                }
                let added = changes.insertions.compactMap { change -> JSONValue? in
                    if case .insert(_, let route, _) = change { return route }
                    return nil
                }
                if !removed.isEmpty { RouteReview(routes: removed, title: "Remove") }
                if !added.isEmpty { RouteReview(routes: added, title: "Add") }
                Text(newRoutes.isEmpty ? "This credential will have no allowed destinations." : "These routes apply to every box using this credential.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}
