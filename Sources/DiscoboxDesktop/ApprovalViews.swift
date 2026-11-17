import SwiftUI
import DiscoboxCore

struct ApprovalInboxView: View {
    @Environment(ConnectionSession.self) private var workspace
    let boxID: String?
    var body: some View { ApprovalQueueContent(workspace: workspace, boxID: boxID) }
}

private struct ApprovalQueueContent: View {
    @Environment(Connections.self) private var connections: Connections?
    @Environment(\.dismiss) private var dismiss
    @State private var queue: ApprovalQueue
    @State private var refreshing = false
    @FocusState private var listFocused: Bool
    init(workspace: ConnectionSession, boxID: String?) {
        self.workspace = workspace
        _queue = State(initialValue: ApprovalQueue(connection: workspace.connectionState, approvals: workspace.approvalStore, boxID: boxID))
    }
    private let workspace: ConnectionSession
    private var subtitle: String {
        let computer = connections?.sessions.first { $0 === workspace }?.profile.displayName
        let box = queue.boxID.flatMap { id in workspace.inventory.sandboxes.first { $0.id == id }?.displayName }
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
                    }.font(.callout).padding(.horizontal, 24).padding(.vertical, 12)
                        .background(DiscoboxAppearance.chrome)
                    Divider()
                    ApprovalSheet(item: item, onClose: {
                        if queue.reviewing?.id == item.id { queue.back() }
                    }).environment(workspace).id(item.id)
                }.frame(width: 720)
            } else {
                StudioConfirmation(title: "Approval requests", symbol: "bell.badge", subtitle: subtitle, width: 720) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = workspace.approvalStore.approvalError { Notice(text: "Could not refresh requests: " + error, symbol: "wifi.exclamationmark") }
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
                                            if queue.boxID == nil { Text(workspace.inventory.sandboxes.first { $0.id == item.boxID }?.displayName ?? item.boxID).font(.caption).foregroundStyle(.secondary) }
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
        .onChange(of: workspace.approvalStore.approvals) { queue.synchronize() }
        .onChange(of: workspace.connectionState.connectionID) { queue.back() }
    }
    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { await workspace.approvalStore.refreshApprovals(); refreshing = false; queue.synchronize() }
    }
}

/// Identity stays visible across both generations of credential approval.
struct ApprovalRequestIdentity: View {
    let item: ApprovalItem
    @Environment(ConnectionSession.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = connections?.sessions.first(where: { $0 === workspace }) {
                LabeledContent("Computer", value: host.profile.displayName)
            }
            LabeledContent("Requesting box", value: workspace.inventory.sandboxes.first { $0.id == item.boxID }?.displayName ?? item.boxID)
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
    @Environment(ConnectionSession.self) private var workspace
    var body: some View {
        LegacyApprovalForm(model: LegacyApprovalReview(item, in: workspace, initialDuration: initialDuration), onClose: onClose)
    }
}

/// Presentation only: the draft and request lifecycle live in the model.
private struct LegacyApprovalForm: View {
    @State private var model: LegacyApprovalReview
    let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    init(model: LegacyApprovalReview, onClose: (() -> Void)?) {
        _model = State(initialValue: model); self.onClose = onClose
    }
    private var item: ApprovalItem { model.item }
    private var request: JSONValue { model.request }
    private var lifecycle: ApprovalReviewLifecycle { model.lifecycle }
    private var busy: Bool { lifecycle.isBusy }
    private var loading: Bool { lifecycle.phase == .loading }
    var body: some View {
        @Bindable var form = model
        let receipt = lifecycle.receipt, resolved = lifecycle.isResolved
        StudioConfirmation(title: receipt != nil ? "Decision recorded" : resolved ? "Request no longer pending" : item.reviewTitle,
                           symbol: item.kind == "trust" ? "checkmark.shield" : "key", width: 680) {
            if let receipt {
                VStack(alignment: .leading, spacing: 12) {
                    Label(lifecycle.receiptAction == "deny" ? "Request denied" : model.isRefresh ? "Credential updated" : "Access approved", systemImage: "checkmark.circle").font(.headline)
                    Text(lifecycle.receiptAction == "deny" ? "No new access was granted. Existing access was left unchanged." : "Discobox recorded this decision on the requesting computer.").foregroundStyle(.secondary)
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
                        if model.isRefresh {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Replace shared token value").font(.headline)
                                Text("Other boxes using this project credential will also use the replacement. Scopes and grant lifetimes stay unchanged.").font(.callout).foregroundStyle(.secondary)
                                SecureField("New token value", text: $form.value)
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
                if let validation = model.validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                if let error = lifecycle.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if receipt == nil && !resolved && item.kind == "trust" {
                    Toggle("I reviewed the access, destination and duration", isOn: $form.reviewed).toggleStyle(.checkbox).font(.callout)
                        .disabled(loading || busy).accessibilityIdentifier("approval.reviewed")
                }
                if receipt == nil && !resolved && item.kind == "credential" {
                    Text(model.creating ? "Save the credential before approving. Deny and Later remain available." : "Approve grants this request’s access within the credential’s limits. Deny grants no new access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(receipt != nil || resolved || busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if receipt == nil && !resolved {
                        if lifecycle.phase == .uncertain {
                            Button("Check again") { Task { await model.recheck() } }
                        } else {
                            Button("Deny", role: .destructive) { _ = model.submit(deny: true) }.disabled(!lifecycle.canDecide)
                            Button(model.isRefresh ? "Update credential" : "Approve") { _ = model.submit(deny: false) }
                                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                                .disabled(!model.canApprove)
                                .accessibilityIdentifier("approval.apply")
                        }
                    } else { Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }
            }
        }.task { await model.load() }
            .onDisappear { model.close() }
    }
    private var credentialChoice: some View {
        @Bindable var form = model
        return VStack(alignment: .leading, spacing: 10) {
            Text("Credential").font(.headline)
            ApprovalCredentialPicker(secretID: $form.secret, creating: $form.creating, secrets: model.secrets, placeholder: "Use the server-configured credential")
                .disabled(busy || loading)
            if model.creating {
                InlineTokenCredentialForm(name: $form.newName, value: $form.value, destinationHost: $form.host,
                    canSave: model.canStoreCredential,
                    save: { _ = model.storeCredential() }, cancel: { model.creating = false }) {
                        Text("Maximum grant lifetime: one hour. Edit shared limits separately in Settings → Credentials.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
            } else {
                Text("Grant limits are checked by Discobox when you approve. Edit shared restrictions separately in Settings → Credentials.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).studioCard()
    }
    private var certificateChoice: some View {
        @Bindable var form = model
        let certificates = model.certificates
        return VStack(alignment: .leading, spacing: 10) {
            Text("Certificate to trust").font(.headline)
            StudioMenuField(title: "Certificate", selection: $form.pin, options:
                [.init(id: "", title: "Choose a certificate…")] + certificates.enumerated().map { .init(id: String($0.offset), title: $0.element["subject"].string) })
            if let index = Int(model.pin), certificates.indices.contains(index) {
                Text(certificates[index].pretty).font(.caption.monospaced()).textSelection(.enabled)
                if certificates[index]["isCA"] == .bool(true) { Text("Trusts this certificate authority for the destination. Review its fingerprint carefully.").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(12).studioCard()
    }
    private var durationPreset: Binding<String> {
        Binding(get: { [ApprovalDuration.automatic, "900", "1800", "3600", "28800", "86400", "0"].contains(model.duration) ? model.duration : "custom" },
                set: { model.duration = $0 == "custom" ? "" : $0 })
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
        @Bindable var form = model
        return VStack(alignment: .leading, spacing: 8) {
            Text("Duration").font(.headline)
            StudioMenuField(title: "Lifetime", selection: durationPreset, options: lifetimeOptions)
            if durationPreset.wrappedValue == "custom" { TextField("Duration in seconds", text: $form.duration) }
            if let maximum = model.maximum { Text(maximum == 0 ? "Credential permits grants without expiry." : "Credential limit: " + ApprovalDuration.label(maximum)).font(.caption).foregroundStyle(.secondary) }
            Text("Automatic uses the server’s bounded duration. A custom lifetime never raises the credential’s limit.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).studioCard()
    }
    private func close() { model.close(); if let onClose { onClose() } else { dismiss() } }
}
