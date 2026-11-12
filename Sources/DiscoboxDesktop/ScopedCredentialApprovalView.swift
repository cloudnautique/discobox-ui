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
    @State private var reviewed = false
    @State private var busy = false
    @State private var loading = true
    @State private var closed = false
    @State private var error: String?
    @State private var receipt: JSONValue?
    @State private var creating = false
    @State private var newName = ""
    @State private var newValue = ""
    @State private var showReason = false
    @State private var reviewRequest = UUID()
    @State private var contextDraft = ""
    private var request: JSONValue { item.request }
    private var secret: JSONValue { context["secrets"].array.first { $0["id"].string == secretID } ?? .null }
    private var payload: JSONValue? { try? CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate) }
    private var validation: String? {
        do { _ = try CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate); return nil }
        catch { return error.localizedDescription }
    }
    private var resolved: Bool { connection != nil && (workspace.connectionID != connection || !workspace.approvals.contains(item)) }
    private var draftKey: String { (payload?.pretty ?? "") + secretID }
    private var conflicts: [JSONValue] { context["conflicts"].array }
    private var contextMatchesDraft: Bool { contextDraft == draftKey }
    private var revision: String { [draftKey, context["fingerprint"].string, context["usePlan"].pretty, context["delegatePlan"].pretty, context["conflicts"].pretty].joined(separator: "|") }
    private var applyTitle: String {
        if request["use"] != .null && request["delegate"] != .null { return "Apply choices" }
        if use.decision == "approve" { return "Allow access" }
        if delegate.decision == "approve" { return "Allow sharing" }
        return "Apply choice"
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
                            if let computer = connections?.sessions.first(where: { $0.workspace === workspace }) { LabeledContent("Computer", value: computer.profile.displayName) }
                            LabeledContent("Requesting box", value: workspace.sandboxes.first { $0.id == item.boxID }?.displayName ?? item.boxID)
                            if !request["envName"].string.isEmpty { LabeledContent("Credential variable", value: request["envName"].string) }
                            if !request["justification"].string.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Why it’s requested · from the box").font(.caption).foregroundStyle(.secondary)
                                    Text(request["justification"].string).lineLimit(showReason ? nil : 3).textSelection(.enabled)
                                    if request["justification"].string.count > 160 { Button(showReason ? "Show less" : "Read full reason") { showReason.toggle() }.font(.caption) }
                                }
                            }
                            if request["use"] != .null { part("Use in this box", value: request["use"], draft: $use, isUse: true) }
                            if request["delegate"] != .null { part("Share with child boxes", value: request["delegate"], draft: $delegate, isUse: false) }
                            credentialChoice
                            if let payload {
                                effectSummary
                                DisclosureGroup("Exact decisions to send") { Text(payload.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                            DisclosureGroup("Full request and constraints") { Text(request.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: conflicts.isEmpty ? 420 : 280).disabled(busy)
                    if !conflicts.isEmpty {
                        CredentialBindingConflictNotice(conflicts: conflicts) {
                            // This edits only the draft. A fresh context and a
                            // new explicit review are required before approval.
                            reviewed = false
                            use.mode = "add"
                        }.disabled(busy || loading || payload == nil)
                    }
                    if loading { Label("Checking current limits and existing access…", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary) }
                    if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if receipt == nil && !resolved {
                    Toggle("I reviewed the requested access and its effect", isOn: $reviewed).toggleStyle(.checkbox).font(.system(size: 12))
                        .disabled(busy || loading || !contextMatchesDraft || payload == nil || !conflicts.isEmpty || context["fingerprint"].string.isEmpty).accessibilityIdentifier("approval.reviewed")
                }
                HStack {
                    Button(receipt != nil || resolved || busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if receipt == nil && !resolved {
                        Button("Reload") { Task { await reload() } }.disabled(busy || loading)
                        Button("Deny request", role: .destructive) { submit(deny: true) }.disabled(busy || connection == nil)
                        Button(applyTitle) { submit(deny: false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(busy || loading || !contextMatchesDraft || !reviewed || payload == nil || !conflicts.isEmpty || context["fingerprint"].string.isEmpty).accessibilityIdentifier("approval.apply")
                    } else { Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }
            }
        }.task {
            connection = workspace.connectionID
            use.mode = request["use"]["add"] == .bool(true) ? "add" : "replace"
            await reload()
        }.task(id: draftKey) {
            guard connection != nil, !busy, payload != nil else { return }
            await reload(selectDefault: false)
        }.onChange(of: use.duration) { _, value in if use.decision == "approve" { delegate.duration = value } }
            .onChange(of: use.decision) { _, value in if value == "approve" { delegate.duration = use.duration } }
            .onChange(of: revision) { reviewed = false }
            .onDisappear { closed = true; newValue = "" }
    }
    private var credentialChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Credential to use").font(.headline)
            Picker("Credential", selection: $secretID) {
                Text("Choose a credential…").tag("")
                ForEach(Array(context["secrets"].array.enumerated()), id: \.offset) { _, row in Text(row["name"].string).tag(row["id"].string) }
            }.disabled(pinned || busy || loading)
            if pinned { Text("The existing box-level credential determines this choice.").font(.caption).foregroundStyle(.secondary) }
            if secret != .null {
                Text(secret["maxBindingTTLSeconds"].number.map { $0 == 0 ? "Credential permits bindings without expiry." : "Maximum lifetime: " + ApprovalDuration.label($0) } ?? "The server chooses a bounded lifetime.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Credential limits") {
                    RouteReview(routes: secret["routes"].array, title: "Allowed destinations")
                    ForEach(Array(secret["routeConstraints"].array.enumerated()), id: \.offset) { index, list in RouteReview(routes: list.array, title: "Additional limit \(index + 1)") }
                }.font(.caption)
            }
            if !pinned {
                DisclosureGroup("Store a new token credential", isExpanded: $creating) {
                    TextField("Credential name", text: $newName)
                    SecureField("Token value", text: $newValue)
                    Text("Creates a credential for the requested routes, including blocks. It does not grant access until you apply a decision. Raw delivery stays off; maximum lifetime is one hour.").font(.caption).foregroundStyle(.secondary)
                    RouteReview(routes: request["use"]["routes"].array + request["delegate"]["routes"].array, title: "New credential routes")
                    Button("Store credential") { createCredential() }.disabled(busy || newName.isEmpty || newValue.isEmpty)
                }.font(.caption)
            }
        }.padding(12).studioCard()
    }
    private var pinned: Bool {
        let held = CredentialDecision.holder(request: request, held: context["held"].array)
        return held["from"].string == "sandbox" && held["fromId"] == request["sandboxId"]
    }
    private func part(_ title: String, value: JSONValue, draft: Binding<CredentialPartDecision>, isUse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if !isUse { Text("Allows giving this credential to child boxes. This does not give the requesting box permission to use it.").font(.callout).foregroundStyle(.secondary) }
            RouteReview(routes: value["routes"].array, title: "Requested access")
            ForEach(Array(value["policies"].array.enumerated()), id: \.offset) { _, policy in
                Text("Box-provided policy: " + policy["name"].string + " — " + policy["description"].string).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Your choice", selection: draft.decision) { Text("Choose…").tag(""); Text("Allow").tag("approve"); Text("Deny").tag("deny") }.pickerStyle(.segmented)
            if draft.wrappedValue.decision == "approve" {
                if draft.wrappedValue.scope != "routes" {
                    Text(draft.wrappedValue.scope == "hosts" ? "Custom scope: every method, path and protocol on the requested open hosts; request blocks are dropped. Credential and parent limits still apply." : "Custom scope: this grant has no route restrictions. Credential and parent limits still apply.").foregroundStyle(.orange).font(.callout)
                }
                Picker("Lifetime", selection: draft.duration) {
                    Text("Automatic · within credential limit").tag(ApprovalDuration.automatic)
                    Text("15 minutes").tag("900"); Text("30 minutes").tag("1800"); Text("1 hour").tag("3600"); Text("8 hours").tag("28800"); Text("No expiry").tag("0")
                }.disabled(!isUse && use.decision == "approve")
                if !isUse && use.decision == "approve" { Text("Uses the same credential and lifetime as this answer’s use grant.").font(.caption).foregroundStyle(.secondary) }
                if isUse {
                    if use.delivery != "sentinel" { Text("The box receives the actual credential value. Route filtering cannot protect a value it already holds.").font(.caption).foregroundStyle(.orange) }
                    DisclosureGroup("Advanced delivery and existing access") {
                        Picker("Existing access", selection: draft.mode) { Text("Replace").tag("replace"); Text("Add beside existing grants").tag("add") }
                        Picker("Delivery", selection: draft.delivery) {
                            Text("Protected placeholder").tag("sentinel")
                            Text("Raw value in variable").tag("env").disabled(secret["allowRaw"] != .bool(true) || use.mode == "add")
                            Text("Path to raw value file").tag("file").disabled(secret["allowRaw"] != .bool(true) || use.mode == "add")
                        }
                    }.font(.caption)
                }
                DisclosureGroup("Advanced scope") {
                    Picker("Scope", selection: draft.scope) { Text("Only requested routes").tag("routes"); Text("Requested hosts").tag("hosts"); Text("Anywhere").tag("anywhere") }
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
        loading = true; error = nil; reviewed = false
        defer { if token == reviewRequest { loading = false } }
        do {
            let result = try await workspace.operation(.approvalContext, requestID: item.id, payload: payload)
            guard !closed, workspace.connectionID == connection, token == reviewRequest, !Task.isCancelled else { return }
            guard result["request"] == request else { throw DiscoboxError("The request changed. Reopen it from the current inbox.") }
            context = result
            contextDraft = requestedDraft
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
        } catch { if !closed, token == reviewRequest, !Task.isCancelled { self.error = error.localizedDescription; context = .null; reviewed = false } }
    }
    private func createCredential() {
        busy = true; error = nil
        let body: JSONValue = .object(["name": .string(newName), "type": .string("token"), "value": .string(newValue), "maxBindingTTLSeconds": .number(3600), "routes": .array(request["use"]["routes"].array + request["delegate"]["routes"].array)])
        Task {
            defer { busy = false; newValue = "" }
            do {
                try await workspace.validateApproval(item, connection: connection!)
                let result = try await workspace.operation(.createSecret, payload: body)
                guard !closed, workspace.connectionID == connection else { return }
                secretID = result["id"].string; creating = false
                await reload(selectDefault: false)
            } catch { if !closed { self.error = error.localizedDescription } }
        }
    }
    private func submit(deny: Bool) {
        guard !busy, !resolved, let connection else { return }
        let decision = payload, fingerprint = context["fingerprint"]
        guard deny || (!loading && contextMatchesDraft && reviewed && decision != nil && conflicts.isEmpty && !fingerprint.string.isEmpty) else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await workspace.validateApproval(item, connection: connection)
                if deny {
                    try await workspace.answer(item, action: "deny", payload: .object([:]), onAccepted: close)
                } else if let decision {
                    try await workspace.answerWithReceipt(item, action: "approve", payload: .object(["approval": decision, "contextFingerprint": fingerprint]), onAccepted: { result in
                        busy = false
                        guard !closed else { return }
                        receipt = result
                        if onClose != nil { close() }
                    })
                }
            } catch { if !closed { self.error = error.localizedDescription; reviewed = false } }
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
