import SwiftUI
import DiscoboxCore

struct ScopedCredentialApprovalView: View {
    let item: ApprovalItem
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
    private var request: JSONValue { item.request }
    private var secret: JSONValue { context["secrets"].array.first { $0["id"].string == secretID } ?? .null }
    private var payload: JSONValue? { try? CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate) }
    private var validation: String? {
        do { _ = try CredentialDecision.payload(request: request, secret: secret, held: context["held"].array, use: use, delegate: delegate); return nil }
        catch { return error.localizedDescription }
    }
    private var resolved: Bool { connection != nil && (workspace.connectionID != connection || !workspace.approvals.contains(item)) }
    private var draftKey: String { (payload?.pretty ?? "") + secretID }
    private var revision: String { draftKey + context["fingerprint"].string + context["usePlan"].pretty + context["delegatePlan"].pretty }
    var body: some View {
        StudioConfirmation(title: receipt != nil ? "Decision recorded" : resolved ? "Request no longer pending" : item.title, symbol: "key", width: 720) {
            if let receipt {
                Text("Discobox recorded your decisions. The receipt below is the server’s immutable record of the granted scopes and lifetime.").foregroundStyle(.secondary)
                ScrollView { receiptSummary(receipt) }.frame(height: 320)
            } else if resolved {
                Text("This request changed, was answered, or its computer reconnected. Open the current inbox to continue.")
            } else {
                ApprovalReview(reviewed: $reviewed, revision: revision) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let computer = connections?.sessions.first(where: { $0.workspace === workspace }) { LabeledContent("Computer", value: computer.profile.displayName) }
                        LabeledContent("Requesting box", value: workspace.sandboxes.first { $0.id == item.boxID }?.displayName ?? item.boxID)
                        LabeledContent("Variable", value: request["envName"].string.isEmpty ? "No variable requested" : request["envName"].string)
                        if request["use"] != .null && request["delegate"] != .null {
                            Label("Two decisions: use in this box, and delegation", systemImage: "list.bullet.rectangle").font(.callout.weight(.medium))
                        }
                        if !request["justification"].string.isEmpty {
                            Text("Reason · from the requesting box").font(.caption).foregroundStyle(.secondary)
                            Text(request["justification"].string).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Credential").font(.headline)
                            Picker("Use credential", selection: $secretID) {
                                Text("Choose a credential…").tag("")
                                ForEach(Array(context["secrets"].array.enumerated()), id: \.offset) { _, row in Text(row["name"].string).tag(row["id"].string) }
                            }.disabled(pinned || busy || loading)
                            if pinned { Text("This box already has this credential in the requested variable, which pins the choice.").font(.caption).foregroundStyle(.secondary) }
                            if secret != .null {
                                Text(secret["maxBindingTTLSeconds"].number.map { $0 == 0 ? "Credential allows bindings without expiry." : "Maximum lifetime: " + ApprovalDuration.label($0) } ?? "The server chooses the bounded lifetime.").font(.caption).foregroundStyle(.secondary)
                                RouteReview(routes: secret["routes"].array, title: "Credential ceiling")
                                ForEach(Array(secret["routeConstraints"].array.enumerated()), id: \.offset) { index, list in RouteReview(routes: list.array, title: "Additional ceiling \(index + 1)") }
                            }
                            if !pinned {
                                DisclosureGroup("Store a new token credential", isExpanded: $creating) {
                                    TextField("Credential name", text: $newName)
                                    SecureField("Token value", text: $newValue)
                                    Text("Creates a project credential with the exact requested route lists combined below, including blocked routes. No binding is created until you apply the decisions. Raw delivery stays off; maximum lifetime is one hour.").font(.caption).foregroundStyle(.secondary)
                                    RouteReview(routes: request["use"]["routes"].array + request["delegate"]["routes"].array, title: "New credential routes")
                                    Button("Store credential") { createCredential() }.disabled(busy || newName.isEmpty || newValue.isEmpty)
                                }
                            }
                        }.padding(12).studioCard()
                        if request["use"] != .null { part("Use in this box", value: request["use"], draft: $use, isUse: true) }
                        if request["delegate"] != .null { part("Delegate to boxes it leads", value: request["delegate"], draft: $delegate, isUse: false) }
                        DisclosureGroup("Full request and constraints") { Text(request.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                        if let payload {
                            effectSummary
                            DisclosureGroup("Exact decisions to send") { Text(payload.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 460)
                if loading { Label("Reading current credential limits and bindings…", systemImage: "arrow.trianglehead.2.clockwise").font(.caption) }
                if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                else if !reviewed { Text("Read to the end of the current review to enable Apply decisions.").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        } footer: {
            HStack {
                Button(receipt != nil || resolved || busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if receipt == nil && !resolved {
                    Button("Reload review") { Task { await reload() } }.disabled(busy)
                    Button("Apply decisions") { submit(deny: false) }.buttonStyle(.bordered)
                        .disabled(busy || loading || !reviewed || payload == nil || context["fingerprint"].string.isEmpty)
                    Button("Deny request", role: .destructive) { submit(deny: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy)
                } else { Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }
        }.task {
            connection = workspace.connectionID
            use.mode = request["use"]["add"] == .bool(true) ? "add" : "replace"
            await reload()
        }.task(id: draftKey) {
            guard connection != nil, !loading, !busy, payload != nil else { return }
            do { try await Task.sleep(for: .milliseconds(300)); await reload(selectDefault: false) } catch {}
        }.onChange(of: use.duration) { _, value in if use.decision == "approve" { delegate.duration = value } }
        .onChange(of: use.decision) { _, value in if value == "approve" { delegate.duration = use.duration } }
        .onDisappear { closed = true; newValue = "" }
    }
    private var pinned: Bool {
        let held = CredentialDecision.holder(request: request, held: context["held"].array)
        return held["from"].string == "sandbox" && held["fromId"] == request["sandboxId"]
    }
    private func part(_ title: String, value: JSONValue, draft: Binding<CredentialPartDecision>, isUse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if !isUse { Text("Allows giving this credential to direct children, within the approved limits. It does not give this box permission to use it.").font(.callout).foregroundStyle(.secondary) }
            RouteReview(routes: value["routes"].array, title: "Requested routes")
            ForEach(Array(value["policies"].array.enumerated()), id: \.offset) { _, policy in
                Text("Policy · box-provided: " + policy["name"].string + " — " + policy["description"].string).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Decision", selection: draft.decision) { Text("Choose…").tag(""); Text("Allow").tag("approve"); Text("Deny").tag("deny") }.pickerStyle(.segmented)
            if draft.wrappedValue.decision == "approve" {
                Picker("Scope", selection: draft.scope) { Text("Requested routes").tag("routes"); Text("Requested hosts").tag("hosts"); Text("Anywhere").tag("anywhere") }
                if draft.wrappedValue.scope != "routes" { Text(draft.wrappedValue.scope == "hosts" ? "Broadens to every method, path and protocol on the requested open hosts; request blocks are dropped. Credential and parent limits still apply." : "Removes this grant’s route restrictions. Credential and parent limits still apply.").foregroundStyle(.orange).font(.callout) }
                Picker("Lifetime", selection: draft.duration) {
                    Text("Automatic · within credential limit").tag(ApprovalDuration.automatic)
                    Text("15 minutes").tag("900"); Text("30 minutes").tag("1800"); Text("1 hour").tag("3600"); Text("8 hours").tag("28800"); Text("No expiry").tag("0")
                }.disabled(!isUse && use.decision == "approve")
                if !isUse && use.decision == "approve" { Text("Uses the same credential and lifetime as this answer’s use grant.").font(.caption).foregroundStyle(.secondary) }
                if isUse {
                    Picker("Existing use", selection: draft.mode) { Text("Replace").tag("replace"); Text("Add beside existing grants").tag("add") }
                    Picker("Delivery", selection: draft.delivery) {
                        Text("Placeholder · value stays in pool").tag("sentinel")
                        Text("Raw value in variable").tag("env").disabled(secret["allowRaw"] != .bool(true) || use.mode == "add")
                        Text("Path to raw value file").tag("file").disabled(secret["allowRaw"] != .bool(true) || use.mode == "add")
                    }
                    if use.delivery != "sentinel" { Text("The box receives the actual credential value and can read it. Route filtering cannot protect a value it already holds.").font(.caption).foregroundStyle(.orange) }
                }
            }
        }.padding(12).studioCard()
    }
    private var effectSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effect on existing access").font(.headline)
            if use.decision == "approve" {
                Text(use.mode == "add" ? "Adds a separate use grant. Existing grants stay as they are." : "Replaces this box’s use of this credential, including additions. Inherited grants can be shadowed for this variable while the replacement lasts.")
            }
            ForEach(["usePlan", "delegatePlan"], id: \.self) { key in
                ForEach(Array(context[key]["Steps"].array.enumerated()), id: \.offset) { _, row in
                    Text(row["Binding"]["ID"].string + " · " + row["Fate"].string).font(.caption.monospaced())
                }
            }
            ForEach(Array(context["held"].array.enumerated()), id: \.offset) { _, row in
                if row["envVar"] == request["envName"] {
                    Text(heldCredentialDescription(row)).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(row["routes"].array.enumerated()), id: \.offset) { index, routes in RouteReview(routes: routes.array, title: "Held ceiling \(index + 1)") }
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
        loading = true; error = nil
        do {
            let result = try await workspace.operation(.approvalContext, requestID: item.id, payload: payload)
            guard !closed, workspace.connectionID == connection else { return }
            guard result["request"] == request else { throw DiscoboxError("The request changed. Reopen it from the current inbox.") }
            context = result
            if selectDefault && secretID.isEmpty {
                let holder = CredentialDecision.holder(request: request, held: result["held"].array)
                secretID = holder["secretId"].string
            }
        } catch { if !closed { self.error = error.localizedDescription; context = .null; reviewed = false } }
        loading = false
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
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await workspace.validateApproval(item, connection: connection)
                if deny {
                    try await workspace.answer(item, action: "deny", payload: .object([:]), onAccepted: close)
                } else if let payload {
                    let result = try await workspace.operation(.answer, requestID: item.id, kind: "credential", action: "approve", payload: .object(["approval": payload, "contextFingerprint": context["fingerprint"]]))
                    guard workspace.connectionID == connection else { return }
                    if !closed { receipt = result }
                    await workspace.refreshApprovals()
                }
            } catch { if !closed { self.error = error.localizedDescription; reviewed = false } }
        }
    }
    private func close() { closed = true; newValue = ""; dismiss() }
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
