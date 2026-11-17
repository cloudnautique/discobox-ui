import SwiftUI
import DiscoboxCore

struct ScopedCredentialApprovalView: View {
    let item: ApprovalItem
    var onClose: (() -> Void)? = nil
    @Environment(ConnectionSession.self) private var workspace
    var body: some View { ScopedCredentialApprovalForm(model: BindingApprovalReview(item, in: workspace), onClose: onClose) }
}

/// Presentation only: drafts, previews and the decision lifecycle live in the model.
private struct ScopedCredentialApprovalForm: View {
    @State private var model: BindingApprovalReview
    let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    init(model: BindingApprovalReview, onClose: (() -> Void)?) {
        _model = State(initialValue: model); self.onClose = onClose
    }
    private var item: ApprovalItem { model.item }
    private var request: JSONValue { model.request }
    private var context: JSONValue { model.context }
    private var secret: JSONValue { model.secret }
    private var lifecycle: ApprovalReviewLifecycle { model.lifecycle }
    private var busy: Bool { lifecycle.isBusy }
    private var loading: Bool { lifecycle.phase == .loading }
    private var conflicts: [JSONValue] { model.conflicts }
    var body: some View {
        @Bindable var form = model
        let receipt = lifecycle.receipt, resolved = lifecycle.isResolved
        StudioConfirmation(title: receipt != nil ? "Decision recorded" : resolved ? "Request no longer pending" : item.reviewTitle, symbol: "key", width: 720) {
            if let receipt {
                Text("Discobox recorded your decision. These are the server’s granted scopes and lifetime.").foregroundStyle(.secondary)
                ScrollView { receiptSummary(receipt) }.frame(height: 320)
            } else if resolved {
                Text("This request changed, was answered, or its computer reconnected. Open the current inbox to continue.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Label(item.intent, systemImage: request["delegate"] != .null ? "person.2" : "key").font(.headline)
                            ApprovalRequestIdentity(item: item)
                            credentialChoice
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Requested access").font(.headline)
                                if request["use"] != .null { Label("Use the credential in this box", systemImage: "key") }
                                if request["delegate"] != .null { Label("Share the requested access with child boxes", systemImage: "person.2") }
                                DisclosureGroup("Exact routes and restrictions") {
                                    if request["use"] != .null { routeDetails("Use in this box", value: request["use"]) }
                                    if request["delegate"] != .null { routeDetails("Share with child boxes", value: request["delegate"]) }
                                }.font(.caption)
                            }.padding(12).studioCard()
                            DisclosureGroup("More options") {
                                if request["use"] != .null && request["delegate"] != .null {
                                    Text("Optionally approve only part of this request. The footer states exactly what will be granted.").font(.caption).foregroundStyle(.secondary)
                                    Toggle("Include use in this box", isOn: Binding(get: { model.approvesUse }, set: { model.use.decision = $0 ? "approve" : "deny" }))
                                    Toggle("Include sharing with child boxes", isOn: Binding(get: { model.approvesSharing }, set: { model.delegate.decision = $0 ? "approve" : "deny" }))
                                }
                                if request["use"] != .null { part("Use in this box", draft: $form.use, isUse: true) }
                                if request["delegate"] != .null { part("Share with child boxes", draft: $form.delegate, isUse: false) }
                                effectSummary
                                if let payload = model.payload { DisclosureGroup("Exact approval to send") { Text(payload.pretty).font(.caption.monospaced()).textSelection(.enabled) } }
                            }.font(.caption)
                            DisclosureGroup("Full request and constraints") { Text(request.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: conflicts.isEmpty ? 420 : 280).disabled(busy)
                    if !conflicts.isEmpty {
                        CredentialBindingConflictNotice(conflicts: conflicts) {
                            // This edits only the draft. A fresh context and a
                            // new explicit review are required before approval.
                            model.addBesideExistingAccess()
                        }.disabled(busy || loading || model.payload == nil)
                    }
                    if loading { Label("Checking current limits and existing access…", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary) }
                    if !busy, !loading, let validation = model.validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                    if let error = lifecycle.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if receipt == nil && !resolved { Text(model.footerSummary).font(.caption).foregroundStyle(.secondary) }
                if busy { Text(lifecycle.status + " You can close this window; check the request before retrying.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("approval.progress") }
                if model.requiresReload { Text("The last action could not be confirmed. Reload before making another decision.").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(receipt != nil || resolved || busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if receipt == nil && !resolved {
                        Button("Reload") { Task { await model.reload(selectDefault: true) } }.disabled(busy || loading)
                        Button("Deny", role: .destructive) { _ = model.submit(deny: true) }.disabled(!lifecycle.canDecide).accessibilityIdentifier("approval.deny")
                        Button(model.applyTitle) { _ = model.submit(deny: false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(!model.canApprove).accessibilityIdentifier("approval.apply")
                    } else { Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }
            }
        }.task { await model.load() }
            .task(id: model.previewKey) { await model.refreshPreview() }
            .onChange(of: model.dismissesAfterReceipt) { if model.dismissesAfterReceipt { close() } }
            .onDisappear { model.close() }
    }
    private var credentialChoice: some View {
        @Bindable var form = model
        let pinned = model.pinned
        return VStack(alignment: .leading, spacing: 10) {
            Text("Credential").font(.headline)
            ApprovalCredentialPicker(secretID: $form.secretID, creating: $form.creating, secrets: context["secrets"].array, canCreate: !pinned)
                .disabled(pinned || busy || loading)
            if pinned { Text("This box’s existing credential determines the choice.").font(.caption).foregroundStyle(.secondary) }
            if model.creating {
                InlineTokenCredentialForm(name: $form.newName, value: $form.newValue,
                    canSave: model.canStoreCredential,
                    save: { _ = model.storeCredential() }, cancel: { model.creating = false }) {
                        Text("Destination: " + item.destinationSummary).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("New credential restrictions") {
                            RouteReview(routes: request["use"]["routes"].array + request["delegate"]["routes"].array, title: "Allowed routes")
                            Text("Maximum lifetime: one hour. Raw delivery is off.").font(.caption).foregroundStyle(.secondary)
                        }.font(.caption)
                    }
            } else if secret != .null {
                Text(secret["maxBindingTTLSeconds"].number.map { $0 == 0 ? "Credential permits bindings without expiry." : "Maximum lifetime: " + ApprovalDuration.label($0) } ?? "The server chooses a bounded lifetime.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Credential limits") {
                    RouteReview(routes: secret["routes"].array, title: "Allowed destinations")
                    ForEach(Array(secret["routeConstraints"].array.enumerated()), id: \.offset) { index, list in RouteReview(routes: list.array, title: "Additional limit \(index + 1)") }
                }.font(.caption)
            }
        }.padding(12).studioCard()
    }
    private func routeDetails(_ title: String, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RouteReview(routes: value["routes"].array, title: title)
            ForEach(Array(value["policies"].array.enumerated()), id: \.offset) { _, policy in
                Text("Box-provided policy: " + policy["name"].string + " — " + policy["description"].string).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func part(_ title: String, draft: Binding<CredentialPartDecision>, isUse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if !isUse { Text("Allows giving this credential to child boxes. This does not give the requesting box permission to use it.").font(.callout).foregroundStyle(.secondary) }
            if draft.wrappedValue.decision == "approve" {
                if draft.wrappedValue.scope != "routes" {
                    Text(draft.wrappedValue.scope == "hosts" ? "Custom scope: every method, path and protocol on the requested open hosts; request blocks are dropped. Credential and parent limits still apply." : "Custom scope: this grant has no route restrictions. Credential and parent limits still apply.").foregroundStyle(.orange).font(.callout)
                }
                StudioMenuField(title: "Lifetime", selection: draft.duration, options: [
                    .init(id: ApprovalDuration.automatic, title: "Automatic · within credential limit"),
                    .init(id: "900", title: "15 minutes"), .init(id: "1800", title: "30 minutes"),
                    .init(id: "3600", title: "1 hour"), .init(id: "28800", title: "8 hours"), .init(id: "0", title: "No expiry")
                ]).disabled(!isUse && model.use.decision == "approve")
                if !isUse && model.use.decision == "approve" { Text("Uses the same credential and lifetime as this answer’s use grant.").font(.caption).foregroundStyle(.secondary) }
                if isUse {
                    if model.use.delivery != "sentinel" { Text("The box receives the actual credential value. Route filtering cannot protect a value it already holds.").font(.caption).foregroundStyle(.orange) }
                    DisclosureGroup("Advanced delivery and existing access") {
                        StudioMenuField(title: "Existing access", selection: draft.mode, options: [
                            .init(id: "replace", title: "Replace"), .init(id: "add", title: "Add beside existing grants")
                        ])
                        StudioMenuField(title: "Delivery", selection: draft.delivery, options: [
                            .init(id: "sentinel", title: "Protected placeholder"),
                            .init(id: "env", title: "Raw value in variable", enabled: secret["allowRaw"] == .bool(true) && model.use.mode != "add"),
                            .init(id: "file", title: "Path to raw value file", enabled: secret["allowRaw"] == .bool(true) && model.use.mode != "add")
                        ])
                    }.font(.caption)
                }
                DisclosureGroup("Advanced scope") {
                    StudioMenuField(title: "Scope", selection: draft.scope, options: [
                        .init(id: "routes", title: "Only requested routes"), .init(id: "hosts", title: "Requested hosts"), .init(id: "anywhere", title: "Anywhere")
                    ])
                }.font(.caption)
            }
        }.padding(12).studioCard()
    }
    private var effectSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effect on existing access").font(.headline)
            if model.use.decision == "approve" {
                Text(model.use.mode == "add" ? "Adds a separate use grant. Existing grants stay as they are." : "Replaces this box’s use of this credential, including additions. Inherited grants can be shadowed for this variable while the replacement lasts.")
            }
            DisclosureGroup("Binding details") {
                ForEach(["usePlan", "delegatePlan"], id: \.self) { key in
                    ForEach(Array(context[key]["Steps"].array.enumerated()), id: \.offset) { _, row in
                        Text(row["Binding"]["ID"].string + " · " + row["Fate"].string).font(.caption.monospaced())
                    }
                }
            }
            ForEach(Array(context["held"].array.enumerated()), id: \.offset) { _, row in
                if row["envVar"] == request["envName"] {
                    Text(heldCredentialDescription(row)).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Existing access limits") {
                        ForEach(Array(row["routes"].array.enumerated()), id: \.offset) { index, routes in RouteReview(routes: routes.array, title: "Limit \(index + 1)") }
                    }
                }
            }
            Text("A denied part leaves its current bindings unchanged. No decision has been sent yet.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).studioCard()
    }
    private func heldCredentialDescription(_ row: JSONValue) -> String {
        let name: String = row["secretName"].string
        let source: String = row["from"].string
        let addition: String = row["adds"] == .bool(true) ? " · addition" : ""
        let expiresAt: String = row["expiresAt"].string
        let expiry: String = expiresAt.isEmpty ? "no expiry" : expiresAt
        return "Currently held: \(name) · \(source)\(addition) · \(expiry)"
    }
    private func receiptSummary(_ result: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(["use", "delegate"], id: \.self) { kind in
                let part = result[kind]
                if part != .null {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(kind == "use" ? "Use in this box" : "Delegation", systemImage: "checkmark.circle") .font(.headline)
                        LabeledContent("Decision", value: part["outcome"].string.capitalized)
                        if part["grant"] != .null {
                            LabeledContent("Scope", value: part["approvedScope"].string)
                            LabeledContent("Mode", value: part["grant"]["mode"].string)
                            LabeledContent("Delivery", value: part["grant"]["delivery"].string)
                            LabeledContent("Expires", value: part["grant"]["expiresAt"].string.isEmpty ? "No expiry" : part["grant"]["expiresAt"].string)
                            ForEach(Array(part["grant"]["routeLists"].array.enumerated()), id: \.offset) { _, list in
                                RouteReview(routes: list["routes"].array, title: list["source"].string + " · " + list["sourceId"].string)
                            }
                        }
                    }.padding(12).studioCard()
                }
            }
            DisclosureGroup("Full server receipt") { Text(result.pretty).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }
    private func close() { guard !lifecycle.closed else { return }; model.close(); if let onClose { onClose() } else { dismiss() } }
}

struct RouteReview: View {
    let routes: [JSONValue]
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if routes.isEmpty { Text("No open routes").font(.caption) }
            ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                VStack(alignment: .leading, spacing: 3) {
                    Label(route["hosts"].array.map(\.string).joined(separator: ", "), systemImage: route["blocked"] == .bool(true) ? "nosign" : "network")
                    Text((route["methods"].array.isEmpty ? "Any method" : route["methods"].array.map(\.string).joined(separator: ", ")) + " · " + (route["paths"].array.isEmpty ? "Any path" : route["paths"].array.map(\.string).joined(separator: ", "))).font(.caption.monospaced())
                    if route["graphql"] != .null { Text("GraphQL: " + route["graphql"].pretty).font(.caption.monospaced()) }
                    if route["mcp"] != .null { Text("MCP tools: " + (route["mcp"]["tools"].array.isEmpty ? "Any tool" : route["mcp"]["tools"].array.map(\.string).joined(separator: ", "))).font(.caption.monospaced()) }
                    if route["blocked"] == .bool(true) { Text("Blocked").font(.caption.weight(.semibold)).foregroundStyle(.red) }
                }.textSelection(.enabled)
            }
        }
    }
}
