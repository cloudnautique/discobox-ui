import SwiftUI
import DiscoboxCore

struct ScopedCredentialApprovalView: View {
    let item: ApprovalItem
    var onClose: (() -> Void)? = nil
    @Environment(Workspace.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(\.dismiss) private var dismiss
    @State private var connection: UUID?
    @State private var context: JSONValue = .null
    @State private var secretID = ""
    @State private var use = CredentialPartDecision()
    @State private var delegate = CredentialPartDecision()
    @State private var busy = false
    @State private var operationStatus = ""
    @State private var requiresReload = false
    @State private var loading = true
    @State private var closed = false
    @State private var error: String?
    @State private var receipt: JSONValue?
    @State private var creating = false
    @State private var newName = ""
    @State private var newValue = ""
    @State private var reviewRequest = UUID()
    @State private var contextDraft = ""
    private var request: JSONValue { item.request }
    private var secret: JSONValue { context["secrets"].array.first { $0["id"].string == secretID } ?? .null }
    private var payload: JSONValue? { try? CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate) }
    private var validation: String? {
        if creating { return nil }
        if secretID.isEmpty { return "Choose an existing credential or add a new one." }
        do { _ = try CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate); return nil }
        catch { return error.localizedDescription }
    }
    private var resolved: Bool { connection != nil && (workspace.connectionID != connection || !workspace.approvals.contains(item)) }
    private var draftKey: String { (payload?.pretty ?? "") + secretID + "|" + String(creating) }
    private var conflicts: [JSONValue] { context["conflicts"].array }
    private var contextMatchesDraft: Bool { contextDraft == draftKey }
    private var approvesUse: Bool { request["use"] != .null && use.decision == "approve" }
    private var approvesSharing: Bool { request["delegate"] != .null && delegate.decision == "approve" }
    private var hasApproval: Bool { approvesUse || approvesSharing }
    private var applyTitle: String {
        if approvesUse && approvesSharing { return "Approve use & sharing" }
        if approvesSharing { return "Approve sharing" }
        return request["delegate"] != .null && approvesUse ? "Approve use only" : "Approve"
    }
    private var footerSummary: String {
        if creating { return "Save the new credential before approving. Deny and Later remain available." }
        if !hasApproval { return "Use Deny to reject the entire request. Existing access stays unchanged." }
        if approvesSharing {
            return approvesUse ? "Approve grants the requested use and sharing with child boxes. Credential limits still apply." : "Approve grants sharing with child boxes. It does not approve use in this box."
        }
        return request["delegate"] != .null ? "Approve grants use only. The sharing part is denied; existing sharing grants stay unchanged." : "Approve grants only this request’s access, within the credential’s limits. Deny grants no new access."
    }
    var body: some View {
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
                                    Toggle("Include use in this box", isOn: Binding(get: { approvesUse }, set: { use.decision = $0 ? "approve" : "deny" }))
                                    Toggle("Include sharing with child boxes", isOn: Binding(get: { approvesSharing }, set: { delegate.decision = $0 ? "approve" : "deny" }))
                                }
                                if request["use"] != .null { part("Use in this box", draft: $use, isUse: true) }
                                if request["delegate"] != .null { part("Share with child boxes", draft: $delegate, isUse: false) }
                                effectSummary
                                if let payload { DisclosureGroup("Exact approval to send") { Text(payload.pretty).font(.caption.monospaced()).textSelection(.enabled) } }
                            }.font(.caption)
                            DisclosureGroup("Full request and constraints") { Text(request.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: conflicts.isEmpty ? 420 : 280).disabled(busy)
                    if !conflicts.isEmpty {
                        CredentialBindingConflictNotice(conflicts: conflicts) {
                            // This edits only the draft. A fresh context and a
                            // new explicit review are required before approval.
                            use.mode = "add"
                        }.disabled(busy || loading || payload == nil)
                    }
                    if loading { Label("Checking current limits and existing access…", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary) }
                    if !busy, !loading, let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if receipt == nil && !resolved { Text(footerSummary).font(.caption).foregroundStyle(.secondary) }
                if busy { Text(operationStatus + " You can close this window; check the request before retrying.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("approval.progress") }
                if requiresReload { Text("The last action could not be confirmed. Reload before making another decision.").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(receipt != nil || resolved || busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if receipt == nil && !resolved {
                        Button("Reload") { Task { await reload() } }.disabled(busy || loading)
                        Button("Deny", role: .destructive) { submit(deny: true) }.disabled(busy || connection == nil || requiresReload).accessibilityIdentifier("approval.deny")
                        Button(applyTitle) { submit(deny: false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(busy || loading || requiresReload || !contextMatchesDraft || creating || !hasApproval || payload == nil || !conflicts.isEmpty || context["fingerprint"].string.isEmpty).accessibilityIdentifier("approval.apply")
                    } else { Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }
            }
        }.task {
            connection = workspace.connectionID
            // These are preview drafts. Only the footer's explicit Approve
            // action sends them; opening the form never grants access.
            if request["use"] != .null { use.decision = "approve" }
            if request["delegate"] != .null { delegate.decision = "approve" }
            use.mode = request["use"]["add"] == .bool(true) ? "add" : "replace"
            newName = request["name"].string
            await reload()
        }.task(id: draftKey + "|" + String(busy)) {
            guard connection != nil, !busy, !creating, !requiresReload, receipt == nil, !resolved, payload != nil else { return }
            await reload(selectDefault: false)
        }.onChange(of: use.duration) { _, value in if use.decision == "approve" { delegate.duration = value } }
            .onChange(of: use.decision) { _, value in if value == "approve" { delegate.duration = use.duration } }
            .onChange(of: creating) { if !creating { newValue = "" } }
            .onDisappear { closed = true; newValue = "" }
    }
    private var credentialChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Credential").font(.headline)
            ApprovalCredentialPicker(secretID: $secretID, creating: $creating, secrets: context["secrets"].array, canCreate: !pinned)
                .disabled(pinned || busy || loading)
            if pinned { Text("This box’s existing credential determines the choice.").font(.caption).foregroundStyle(.secondary) }
            if creating {
                InlineTokenCredentialForm(name: $newName, value: $newValue,
                    canSave: !busy && !loading && !requiresReload && !newName.isEmpty && !newValue.isEmpty,
                    save: createCredential, cancel: { creating = false; newValue = "" }) {
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
    private var pinned: Bool {
        let held = CredentialDecision.holder(request: request, held: context["held"].array)
        return held["from"].string == "sandbox" && held["fromId"] == request["sandboxId"]
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
                ]).disabled(!isUse && use.decision == "approve")
                if !isUse && use.decision == "approve" { Text("Uses the same credential and lifetime as this answer’s use grant.").font(.caption).foregroundStyle(.secondary) }
                if isUse {
                    if use.delivery != "sentinel" { Text("The box receives the actual credential value. Route filtering cannot protect a value it already holds.").font(.caption).foregroundStyle(.orange) }
                    DisclosureGroup("Advanced delivery and existing access") {
                        StudioMenuField(title: "Existing access", selection: draft.mode, options: [
                            .init(id: "replace", title: "Replace"), .init(id: "add", title: "Add beside existing grants")
                        ])
                        StudioMenuField(title: "Delivery", selection: draft.delivery, options: [
                            .init(id: "sentinel", title: "Protected placeholder"),
                            .init(id: "env", title: "Raw value in variable", enabled: secret["allowRaw"] == .bool(true) && use.mode != "add"),
                            .init(id: "file", title: "Path to raw value file", enabled: secret["allowRaw"] == .bool(true) && use.mode != "add")
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
            if use.decision == "approve" {
                Text(use.mode == "add" ? "Adds a separate use grant. Existing grants stay as they are." : "Replaces this box’s use of this credential, including additions. Inherited grants can be shadowed for this variable while the replacement lasts.")
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
    private func reload(selectDefault: Bool = true) async {
        guard !closed, !resolved else { return }
        let token = UUID(); reviewRequest = token
        let requestedDraft = draftKey
        loading = true; error = nil
        defer { if token == reviewRequest { loading = false } }
        do {
            let result = try await workspace.operation(.approvalContext, requestID: item.id, payload: payload)
            guard !closed, workspace.connectionID == connection, token == reviewRequest, !Task.isCancelled else { return }
            guard result["request"] == request else { throw DiscoboxError("The request changed. Reopen it from the current inbox.") }
            context = result
            contextDraft = requestedDraft
            requiresReload = false
            if selectDefault && secretID.isEmpty {
                let holder = CredentialDecision.holder(request: request, held: result["held"].array)
                secretID = holder["secretId"].string
                if secretID.isEmpty {
                    let matching = result["secrets"].array.filter {
                        !request["wellKnownId"].string.isEmpty && $0["wellKnownId"] == request["wellKnownId"]
                    }
                    if matching.count == 1 { secretID = matching[0]["id"].string }
                }
            }
        } catch { if !closed, token == reviewRequest, !Task.isCancelled { self.error = error.localizedDescription; contextDraft = "" } }
    }
    private func createCredential() {
        guard !busy, !loading, !requiresReload, creating, let connection else { return }
        busy = true; error = nil; operationStatus = "Checking the request…"
        let body: JSONValue
        do { body = try TokenCredentialPayload.current(name: newName, value: newValue, routes: request["use"]["routes"].array + request["delegate"]["routes"].array) }
        catch { busy = false; self.error = error.localizedDescription; return }
        Task {
            defer { busy = false; newValue = "" }
            do {
                try await workspace.validateApproval(item, connection: connection)
                guard !closed else { return }
                operationStatus = "Storing the credential on the requesting computer…"
                let result = try await workspace.operation(.createSecret, payload: body)
                guard !closed, workspace.connectionID == connection else { return }
                guard !result["id"].string.isEmpty else { throw DiscoboxError("Credential may have been stored. Check Settings → Credentials before retrying.") }
                secretID = result["id"].string; creating = false
                await reload(selectDefault: false)
            } catch { if !closed { self.error = error.localizedDescription; requiresReload = true } }
        }
    }
    private func submit(deny: Bool) {
        guard !busy, !requiresReload, !resolved, let connection else { return }
        let decision = payload, fingerprint = context["fingerprint"]
        guard deny || (!loading && contextMatchesDraft && !creating && hasApproval && decision != nil && conflicts.isEmpty && !fingerprint.string.isEmpty) else { return }
        busy = true; error = nil; operationStatus = "Checking the request on the requesting computer…"
        Task {
            defer { busy = false }
            do {
                try await workspace.validateApproval(item, connection: connection)
                guard !closed else { return }
                operationStatus = "Waiting for the requesting computer to record your decision…"
                if deny {
                    try await workspace.answer(item, action: "deny", payload: .object([:]), onAccepted: close)
                } else if let decision {
                    try await workspace.answerWithReceipt(item, action: "approve", payload: .object(["approval": decision, "contextFingerprint": fingerprint]), onAccepted: { result in
                        busy = false
                        guard !closed else { return }
                        receipt = result
                    })
                }
            } catch { if !closed { self.error = error.localizedDescription; requiresReload = true } }
        }
    }
    private func close() { guard !closed else { return }; closed = true; newValue = ""; if let onClose { onClose() } else { dismiss() } }
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
