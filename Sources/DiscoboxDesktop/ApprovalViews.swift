import SwiftUI
import DiscoboxCore

struct ApprovalInboxView: View {
    @Environment(Workspace.self) private var workspace
    let boxID: String?
    var body: some View { ApprovalQueueContent(workspace: workspace, boxID: boxID) }
}

private struct ApprovalQueueContent: View {
    @Environment(Connections.self) private var connections: Connections?
    @Environment(\.dismiss) private var dismiss
    @State private var queue: ApprovalQueue
    @State private var refreshing = false
    @FocusState private var listFocused: Bool
    init(workspace: Workspace, boxID: String?) {
        _queue = State(initialValue: ApprovalQueue(workspace: workspace, boxID: boxID))
    }
    private var workspace: Workspace { queue.workspace }
    private var subtitle: String {
        let computer = connections?.sessions.first { $0.workspace === workspace }?.profile.displayName
        let box = queue.boxID.flatMap { id in workspace.sandboxes.first { $0.id == id }?.displayName }
        return [computer, box].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        @Bindable var queue = queue
        Group {
            if let item = queue.reviewing {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to requests", systemImage: "chevron.left") { queue.back() }
                        Spacer()
                        Text("\(queue.requests.count) pending").font(.caption).foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(.horizontal, 24).padding(.vertical, 12)
                        .background(DiscoboxAppearance.chrome)
                    Divider()
                    ApprovalSheet(item: item, onClose: {
                        if queue.reviewing?.id == item.id { queue.back() }
                    }).environment(workspace).id(item.id)
                }.frame(width: 720)
            } else {
                StudioConfirmation(title: "Approval requests", symbol: "bell.badge", subtitle: subtitle, width: 720) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = workspace.approvalError { Notice(text: "Could not refresh requests: " + error, symbol: "wifi.exclamationmark") }
                        if !queue.valid {
                            ContentUnavailableView("Connection changed", systemImage: "network", description: Text("Reopen the inbox on this computer."))
                        } else if queue.requests.isEmpty {
                            ContentUnavailableView("No pending requests", systemImage: "checkmark.circle", description: Text("There is nothing left to answer in this inbox."))
                        } else {
                            Text("Review each request to allow or deny it. Closing this window leaves requests pending.").font(.callout).foregroundStyle(.secondary)
                            List(selection: $queue.selection) {
                                ForEach(queue.requests) { item in
                                    HStack(spacing: 12) {
                                        Image(systemName: item.intent.contains("Share") || item.intent.contains("share") ? "person.2" : item.kind == "credential" ? "key" : "checkmark.shield")
                                            .foregroundStyle(DiscoboxAppearance.accent).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack { Text(item.reviewTitle).fontWeight(.semibold); Text(item.intent).font(.caption).foregroundStyle(.secondary) }
                                            if queue.boxID == nil { Text(workspace.sandboxes.first { $0.id == item.boxID }?.displayName ?? item.boxID).font(.caption).foregroundStyle(.secondary) }
                                            if !item.destinationSummary.isEmpty { Text(item.destinationSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                            if !item.request["justification"].string.isEmpty { Text(item.request["justification"].string).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Button("Review", systemImage: "chevron.right") { queue.review(item) }
                                            .buttonStyle(.borderless).accessibilityIdentifier("approval.review." + item.id)
                                    }.padding(.vertical, 8).contentShape(Rectangle()).tag(item.id)
                                }
                            }.listStyle(.inset).scrollContentBackground(.hidden).studioCard().focused($listFocused)
                                .onKeyPress(.return) { queue.reviewSelected(); return .handled }
                        }
                    }.frame(height: 340)
                } footer: {
                    HStack {
                        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh requests").disabled(refreshing || !queue.valid)
                        if refreshing { ProgressView().controlSize(.small) }
                        Spacer()
                        Text("\(queue.requests.count) pending").font(.caption).foregroundStyle(.secondary)
                        if !queue.requests.isEmpty {
                            Button("Review selected") { queue.reviewSelected() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                                .disabled(queue.selected == nil).accessibilityIdentifier("approval.reviewSelected")
                        }
                    }
                }
            }
        }
        .onAppear { queue.synchronize(); listFocused = true }
        .onChange(of: queue.reviewing) { listFocused = queue.reviewing == nil }
        .onChange(of: workspace.approvals) { queue.synchronize() }
        .onChange(of: workspace.connectionID) { queue.back() }
    }
    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { await workspace.refreshApprovals(); refreshing = false; queue.synchronize() }
    }
}

/// Identity stays visible across both generations of credential approval.
struct ApprovalRequestIdentity: View {
    let item: ApprovalItem
    @Environment(Workspace.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = connections?.sessions.first(where: { $0.workspace === workspace }) {
                LabeledContent("Computer", value: host.profile.displayName)
            }
            LabeledContent("Requesting box", value: workspace.sandboxes.first { $0.id == item.boxID }?.displayName ?? item.boxID)
            LabeledContent("Access", value: item.intent)
            if !item.destinationSummary.isEmpty { LabeledContent("Destination", value: item.destinationSummary) }
            if !item.request["envName"].string.isEmpty { LabeledContent("Variable", value: item.request["envName"].string) }
            if !item.request["justification"].string.isEmpty {
                Text("Reason · from the requesting box").font(.caption).foregroundStyle(.secondary)
                Text(item.request["justification"].string).textSelection(.enabled)
            }
        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12).studioCard()
    }
}

/// A compatibility adapter for old grant APIs and certificate pins. Its wire
/// payload remains separate from binding approvals. Shared restrictions and
/// future auto-approval rules are never edited as a side effect of approval.
struct LegacyApprovalSheet: View {
    let item: ApprovalItem
    var initialDuration: String? = nil
    var onClose: (() -> Void)? = nil
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var connection: UUID?
    @State private var secrets: [JSONValue] = []
    @State private var secret = ""
    @State private var duration = ApprovalDuration.automatic
    @State private var value = ""
    @State private var newName = ""
    @State private var creating = false
    @State private var host = ""
    @State private var pin = ""
    @State private var reviewed = false
    @State private var loading = true
    @State private var busy = false
    @State private var closed = false
    @State private var error: String?
    @State private var receipt: JSONValue?
    @State private var receiptAction = ""
    private var request: JSONValue { item.request }
    private var refresh: Bool { request["reason"].string == "refresh" }
    private var resolved: Bool { connection != nil && (workspace.connectionID != connection || !workspace.approvals.contains(item)) }
    private var certificates: [JSONValue] { request["observedChain"].array + (request["suppliedCA"] == .null ? [] : [request["suppliedCA"]]) }
    private var selectedSecret: JSONValue { ApprovalDuration.selectedSecret(id: secret, request: request, secrets: secrets) }
    private var maximum: Double? { item.kind == "credential" ? selectedSecret["maxGrantTTLSeconds"].number : nil }
    private var validation: String? {
        if refresh { return value.isEmpty ? "Enter a replacement token." : nil }
        do { _ = try ApprovalDuration.fields(duration, kind: item.kind, maximum: maximum); return nil }
        catch { return error.localizedDescription }
    }
    private var revision: String { [secret, duration, pin, value, request.pretty, selectedSecret.pretty].joined(separator: "|") }
    var body: some View {
        StudioConfirmation(title: receipt != nil ? "Decision recorded" : resolved ? "Request no longer pending" : item.reviewTitle,
                           symbol: item.kind == "trust" ? "checkmark.shield" : "key", width: 680) {
            if let receipt {
                VStack(alignment: .leading, spacing: 12) {
                    Label(receiptAction == "deny" ? "Request denied" : refresh ? "Credential updated" : "Access approved", systemImage: "checkmark.circle").font(.headline)
                    Text(receiptAction == "deny" ? "No new access was granted. Existing access was left unchanged." : "Discobox recorded this decision on the requesting computer.").foregroundStyle(.secondary)
                    DisclosureGroup("Server receipt") { ScrollView { Text(receipt.pretty).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 250) }
                }
            } else if resolved {
                Text("This request changed, was answered elsewhere, or its computer reconnected. Open the current inbox to continue.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ApprovalRequestIdentity(item: item)
                        Text(item.kind == "trust" ? "Certificate trust applies to the destination above." : "This computer uses the legacy credential approval API. Your choice applies to this request; shared credential restrictions stay unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                        if refresh {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Replace shared token value").font(.headline)
                                Text("Other boxes using this project credential will also use the replacement. Scopes and grant lifetimes stay unchanged.").font(.callout).foregroundStyle(.secondary)
                                SecureField("New token value", text: $value)
                            }.padding(12).studioCard()
                        } else {
                            if item.kind == "trust" { certificateChoice } else { credentialChoice }
                            durationChoice
                            if item.kind == "credential" {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Requested permissions").font(.headline)
                                    if request["policy"] != .null { Text(request["policy"].pretty).font(.caption.monospaced()).textSelection(.enabled) }
                                    if request["uses"] != .null { Text(request["uses"].pretty).font(.caption.monospaced()).textSelection(.enabled) }
                                    Text("Only the requested policy is sent. This answer creates no future auto-approval rule and changes no stored credential limits.").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).studioCard()
                            }
                        }
                        DisclosureGroup("Full request") { Text(request.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 420).disabled(busy)
                if loading { ProgressView("Loading credential metadata…").controlSize(.small) }
                if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if receipt == nil && !resolved && item.kind == "trust" {
                    Toggle("I reviewed the access, destination and duration", isOn: $reviewed).toggleStyle(.checkbox).font(.system(size: 12))
                        .disabled(loading || busy).accessibilityIdentifier("approval.reviewed")
                }
                if receipt == nil && !resolved && item.kind == "credential" {
                    Text(creating ? "Save the credential before approving. Deny and Later remain available." : "Approve grants this request’s access within the credential’s limits. Deny grants no new access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(receipt != nil || resolved || busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if receipt == nil && !resolved {
                        Button("Deny", role: .destructive) { submit(deny: true) }.disabled(busy || connection == nil)
                        Button(refresh ? "Update credential" : "Approve") { submit(deny: false) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(loading || busy || creating || item.kind == "trust" && !reviewed || validation != nil || item.kind == "trust" && pin.isEmpty)
                            .accessibilityIdentifier("approval.apply")
                    } else { Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }
            }
        }.task {
            connection = workspace.connectionID
            let requested = request["grantTTLSeconds"].number ?? 3600
            let trustDuration = requested.isFinite && requested > 0 && requested < Double(Int.max) ? String(Int(requested)) : "3600"
            duration = initialDuration ?? (item.kind == "trust" ? trustDuration : ApprovalDuration.automatic)
            newName = request["name"].string
            host = request["hosts"].array.count == 1 ? request["hosts"].array[0].string : ""
            defer { loading = false }
            do {
                if item.kind == "credential" {
                    let loaded = try await workspace.approvalSecrets()
                    guard !closed, !Task.isCancelled, connection == workspace.connectionID else { return }
                    secrets = loaded
                    let configured = ApprovalDuration.selectedSecret(id: secret, request: request, secrets: loaded)
                    if secret.isEmpty, !configured["id"].string.isEmpty { secret = configured["id"].string }
                }
            } catch { if !closed, !Task.isCancelled { self.error = error.localizedDescription } }
        }.onChange(of: revision) { reviewed = false }
            .onChange(of: creating) { if !creating { value = "" } }
            .onDisappear { closed = true; value = "" }
    }
    private var credentialChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Credential").font(.headline)
            ApprovalCredentialPicker(secretID: $secret, creating: $creating, secrets: secrets, placeholder: "Use the server-configured credential")
                .disabled(busy || loading)
            if creating {
                InlineTokenCredentialForm(name: $newName, value: $value, destinationHost: $host,
                    canSave: !busy && !loading && !newName.isEmpty && !value.isEmpty && !host.isEmpty,
                    save: storeCredential, cancel: { creating = false; value = "" }) {
                        Text("Maximum grant lifetime: one hour. Edit shared limits separately in Settings → Credentials.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
            } else {
                Text("Grant limits are checked by Discobox when you approve. Edit shared restrictions separately in Settings → Credentials.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).studioCard()
    }
    private var certificateChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Certificate to trust").font(.headline)
            StudioMenuField(title: "Certificate", selection: $pin, options:
                [.init(id: "", title: "Choose a certificate…")] + certificates.enumerated().map { .init(id: String($0.offset), title: $0.element["subject"].string) })
            if let index = Int(pin), certificates.indices.contains(index) {
                Text(certificates[index].pretty).font(.caption.monospaced()).textSelection(.enabled)
                if certificates[index]["isCA"] == .bool(true) { Text("Trusts this certificate authority for the destination. Review its fingerprint carefully.").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(12).studioCard()
    }
    private var durationPreset: Binding<String> {
        Binding(get: { [ApprovalDuration.automatic, "900", "1800", "3600", "28800", "86400", "0"].contains(duration) ? duration : "custom" },
                set: { duration = $0 == "custom" ? "" : $0 })
    }
    private var lifetimeOptions: [StudioMenuPicker.Option] {
        var options: [StudioMenuPicker.Option] = [
            .init(id: "900", title: "15 minutes"), .init(id: "1800", title: "30 minutes"),
            .init(id: "3600", title: "1 hour"), .init(id: "28800", title: "8 hours"), .init(id: "86400", title: "1 day")
        ]
        if item.kind == "credential" {
            options.insert(.init(id: ApprovalDuration.automatic, title: "Automatic · within credential limit"), at: 0)
            options.append(.init(id: "0", title: "No expiry"))
        }
        options.append(.init(id: "custom", title: "Custom…"))
        return options
    }
    private var durationChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Duration").font(.headline)
            StudioMenuField(title: "Lifetime", selection: durationPreset, options: lifetimeOptions)
            if durationPreset.wrappedValue == "custom" { TextField("Duration in seconds", text: $duration) }
            if let maximum { Text(maximum == 0 ? "Credential permits grants without expiry." : "Credential limit: " + ApprovalDuration.label(maximum)).font(.caption).foregroundStyle(.secondary) }
            Text("Automatic uses the server’s bounded duration. A custom lifetime never raises the credential’s limit.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).studioCard()
    }
    private func storeCredential() {
        guard !busy, !loading, creating, let connection else { return }
        let body: JSONValue
        do { body = try TokenCredentialPayload.legacy(name: newName, value: value, host: host, maximum: 3600) }
        catch { self.error = error.localizedDescription; return }
        busy = true; error = nil
        Task {
            defer { busy = false; value = "" }
            do {
                try await workspace.validateApproval(item, connection: connection)
                let made = try await workspace.operation(.createSecret, payload: body)
                guard !closed, workspace.connectionID == connection else { return }
                guard !made["id"].string.isEmpty else { throw DiscoboxError("Credential may have been stored. Check Settings → Credentials before retrying.") }
                secret = made["id"].string
                creating = false; value = ""
                secrets = try await workspace.approvalSecrets()
                reviewed = false
            } catch { if !closed { self.error = error.localizedDescription } }
        }
    }
    private func submit(deny: Bool) {
        guard !busy, !resolved, let connection, deny || !creating && (item.kind != "trust" || reviewed) && validation == nil else { return }
        let body: JSONValue
        do {
            if deny { body = .object([:]) }
            else if refresh { body = .object(["value": .string(value), "via": .string("entered")]) }
            else if item.kind == "credential" { body = try LegacyCredentialDecision.payload(request: request, secretID: secret, duration: duration, maximum: maximum) }
            else {
                guard let index = Int(pin), certificates.indices.contains(index) else { throw DiscoboxError("Choose a certificate to trust.") }
                let cert = certificates[index], ca = cert["isCA"] == .bool(true)
                var fields = try ApprovalDuration.fields(duration, kind: "trust", maximum: nil)
                fields["pin"] = .object(["kind": .string(ca ? "ca" : "leaf-spki"), "sha256": cert[ca ? "sha256" : "spkiSha256"]])
                body = .object(fields)
            }
        } catch { self.error = error.localizedDescription; return }
        let action = deny ? "deny" : refresh ? "refresh" : "approve"
        busy = true; error = nil
        Task {
            defer { busy = false; value = "" }
            do {
                try await workspace.validateApproval(item, connection: connection)
                try await workspace.answerWithReceipt(item, action: action, payload: body) { result in
                    guard !closed else { return }
                    receipt = result; receiptAction = action
                }
            } catch {
                if !closed { self.error = error.localizedDescription; reviewed = false }
                else if workspace.connectionID == connection { workspace.commandError = error.localizedDescription }
            }
        }
    }
    private func close() { closed = true; value = ""; if let onClose { onClose() } else { dismiss() } }
}
