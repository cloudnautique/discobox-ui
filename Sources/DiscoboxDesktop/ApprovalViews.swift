import SwiftUI
import DiscoboxCore

struct ApprovalInboxView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let boxID: String?
    @State private var selected: ApprovalItem?
    private var requests: [ApprovalItem] { workspace.approvals.filter { boxID == nil || $0.boxID == boxID } }
    var body: some View {
        if let item = selected ?? (requests.count == 1 ? requests.first : nil) {
            // Present the form in this sheet, without an intermediate inbox or
            // a nested sheet. Retain the item if polling resolves it elsewhere.
            ApprovalSheet(item: item).environment(workspace)
                .id(item.id)
                .onAppear { selected = item }
        } else {
            StudioConfirmation(title: "Needs your attention", symbol: "bell.badge", width: 620) {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = workspace.approvalError { Notice(text: "Inbox refresh failed: " + error, symbol: "wifi.exclamationmark") }
                    List(requests) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(item.title, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                                Text(item.request["justification"].string).lineLimit(3).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }.listStyle(.plain).scrollContentBackground(.hidden).studioCard()
                        .overlay { if requests.isEmpty { ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle") } }
                }
            } footer: {
                HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction) }
            }.frame(height: 460)
        }
    }
}

struct LegacyApprovalSheet: View {
    @Environment(Connections.self) private var connections: Connections?
    let item: ApprovalItem
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var connection: UUID?
    @State private var secrets: [JSONValue] = []
    @State private var secret = ""
    @State private var duration = ApprovalDuration.automatic
    @State private var value = ""
    @State private var newName = ""
    @State private var newCredential = false
    @State private var pin = ""
    @State private var rule = false
    @State private var repositories = ""
    @State private var everyBox = false
    @State private var ruleDays = "7"
    @State private var changeSecret = false
    @State private var host = ""
    @State private var limit = "3600"
    @State private var busy = false
    @State private var error: String?
    @State private var closed = false
    init(item: ApprovalItem, initialDuration: String? = nil) {
        self.item = item
        let wanted = item.request["grantTTLSeconds"].number ?? 3600
        let explicit = wanted.isFinite && wanted >= 0 && wanted < Double(Int.max) ? String(Int(wanted)) : "3600"
        _duration = State(initialValue: initialDuration ?? (item.kind == "credential" ? ApprovalDuration.automatic : explicit))
    }
    private var request: JSONValue { item.request }
    private var refresh: Bool { request["reason"].string == "refresh" }
    private var connectionChanged: Bool { connection.map { $0 != workspace.connectionID } ?? false }
    private var resolved: Bool { connectionChanged || !workspace.approvals.contains { $0.id == item.id } }
    private var certificates: [JSONValue] { request["observedChain"].array + (request["suppliedCA"] == .null ? [] : [request["suppliedCA"]]) }
    private var selectedSecret: JSONValue { ApprovalDuration.selectedSecret(id: secret, request: request, secrets: secrets) }
    private var credentialMaximum: Double? {
        guard item.kind == "credential", !newCredential else { return nil }
        if changeSecret { return Int(limit).flatMap { $0 >= 0 ? Double($0) : nil } }
        return selectedSecret["maxGrantTTLSeconds"].number
    }
    private var durationError: String? {
        guard !refresh else { return nil }
        do { _ = try ApprovalDuration.fields(duration, kind: item.kind, maximum: credentialMaximum); return nil }
        catch { return error.localizedDescription }
    }
    private func permitsDuration(_ value: String) -> Bool {
        (try? ApprovalDuration.fields(value, kind: item.kind, maximum: credentialMaximum)) != nil
    }
    private var durationPreset: Binding<String> {
        Binding(get: {
            [ApprovalDuration.automatic, "900", "1800", "3600", "28800", "86400", "0"].contains(duration) ? duration : "custom"
        }, set: { duration = $0 == "custom" ? "" : $0 })
    }
    var body: some View {
        Group {
            if resolved && !busy {
                StudioConfirmation(title: connectionChanged ? "Connection changed" : "Request no longer pending", symbol: "checkmark.circle") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(connectionChanged ? "Reopen the current approval inbox on this computer." : "This request was answered or withdrawn. There’s nothing left to approve here.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(item.title).font(.callout.weight(.medium))
                    }
                } footer: {
                    HStack { Spacer(); Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }.onExitCommand(perform: close)
            } else { form }
        }.onDisappear { closed = true }
    }
    private func close() { closed = true; dismiss() }

    private var form: some View {
        StudioConfirmation(title: item.title, symbol: item.kind == "trust" ? "checkmark.shield" : "key",
                           subtitle: connections?.sessions.first { $0.workspace === workspace }?.profile.displayName, width: 660) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    Form {
                        Section("Request") {
                        if let host = connections?.sessions.first(where: { $0.workspace === workspace }) { LabeledContent("Computer", value: host.profile.displayName) }
                            LabeledContent("Box", value: workspace.sandboxes.first { $0.id == item.boxID }?.displayName ?? item.boxID)
                            if request["purpose"].string == "delegate" { Text("Delegation: this allows handing access to other boxes, not using the credential directly.").foregroundStyle(.orange) }
                            if !request["justification"].string.isEmpty { Text(request["justification"].string).textSelection(.enabled) }
                            LabeledContent("Destination", value: item.kind == "trust" ? request["host"].string : request["hosts"].array.map(\.string).joined(separator: ", "))
                            if !request["envName"].string.isEmpty { LabeledContent("Delivered as", value: request["envName"].string) }
                        }
                        if refresh {
                            Section("Replace credential value") {
                                SecureField("New token value", text: $value)
                                Text("Writes the new value to the existing project credential and answers this refresh request.").font(.caption)
                            }
                        } else {
                            if item.kind == "trust" {
                                Section("Certificate to trust") {
                                    Picker("Pin", selection: $pin) {
                                        Text("Choose a certificate").tag("")
                                        ForEach(Array(certificates.enumerated()), id: \.offset) { index, cert in
                                            Text(cert["subject"].string + " · " + cert["sha256"].string.prefix(12)).tag(String(index))
                                        }
                                    }
                                    if let index = Int(pin), certificates.indices.contains(index) { Text(certificates[index].pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                }
                            } else {
                                Section("Credential") {
                                    Picker("Use credential", selection: $secret) {
                                        Text("Use the configured credential / gate").tag("")
                                        ForEach(Array(secrets.enumerated()), id: \.offset) { _, entry in Text(entry["name"].string + " · " + entry["host"].string).tag(entry["id"].string) }
                                    }.disabled(newCredential)
                                    Toggle("Store a new token credential", isOn: $newCredential)
                                    if newCredential { TextField("Name", text: $newName); SecureField("Token value", text: $value); TextField("Host", text: $host) }
                                    if let max = selectedSecret["maxGrantTTLSeconds"].number, max.isFinite, max >= 0 {
                                        Text(max == 0 ? "Credential permits non-expiring grants." : "Credential grant limit: " + ApprovalDuration.label(max) + ".").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Section("Duration") {
                                Picker("Preset", selection: durationPreset) {
                                    if item.kind == "credential", !newCredential {
                                        Text("Automatic · respects credential limit").tag(ApprovalDuration.automatic)
                                    }
                                    Text("15 minutes").tag("900").disabled(!permitsDuration("900"))
                                    Text("30 minutes").tag("1800").disabled(!permitsDuration("1800"))
                                    Text("1 hour").tag("3600").disabled(!permitsDuration("3600"))
                                    Text("8 hours").tag("28800").disabled(!permitsDuration("28800"))
                                    Text("1 day").tag("86400").disabled(!permitsDuration("86400"))
                                    if item.kind != "trust" { Text("Never expires").tag("0").disabled(!permitsDuration("0")) }
                                    Text("Custom…").tag("custom")
                                }
                                if duration == ApprovalDuration.automatic {
                                    Text("Uses the requested duration, shortened to the credential’s current limit. The server applies that limit when you approve.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else { TextField("Duration in seconds", text: $duration) }
                                if let wanted = request["grantTTLSeconds"].number, wanted.isFinite, wanted >= 0 {
                                    Text(wanted == 0 ? "Requested: server default" : "Requested: " + ApprovalDuration.label(wanted)).font(.caption).foregroundStyle(.secondary)
                                }
                                if let durationError { Text(durationError).font(.caption).foregroundStyle(.orange) }
                            }
                            if item.kind == "credential" {
                                DisclosureGroup("Permissions and policy") {
                                    Text(request["policy"].pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    Text(request["uses"].pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                                DisclosureGroup("Advanced approval") {
                                    Toggle("Also create an auto-approval rule", isOn: $rule)
                                    if rule {
                                        Text("The rule approves future requests covered by the policy shown above, for the selected repositories.").font(.caption)
                                        TextField("Repository URLs (comma separated)", text: $repositories).disabled(everyBox)
                                        Toggle("Every box in this project, including future boxes", isOn: $everyBox)
                                        TextField("Rule expires after days", text: $ruleDays)
                                    }
                                    Toggle("Change the stored credential’s restrictions", isOn: $changeSecret).disabled(secret.isEmpty || newCredential)
                                    if changeSecret { TextField("New host binding (empty removes binding)", text: $host); TextField("New maximum grant duration (seconds; 0 means no limit)", text: $limit) }
                                }
                            }
                        }
                        DisclosureGroup("Raw request") { Text(request.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.formStyle(.grouped).scrollContentBackground(.hidden)
                }
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if busy {
                    Text("Waiting for Discobox. You can close this window; the submitted response may still complete.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            HStack {
                Button(busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(refresh ? "Update credential" : "Approve") { submit(deny: false) }
                    .buttonStyle(.bordered).disabled(busy || resolved || durationError != nil)
                Button("Deny", role: .destructive) { submit(deny: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(busy || resolved)
            }
        }
        .frame(height: 700).interactiveDismissDisabled(busy)
        .task {
            connection = workspace.connectionID
            newName = request["name"].string
            do {
                if item.kind == "credential" {
                    let loaded = try await workspace.approvalSecrets()
                    guard !Task.isCancelled, connection == workspace.connectionID else { return }
                    secrets = loaded
                }
            }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: newCredential) { _, enabled in
            if enabled && duration == ApprovalDuration.automatic {
                let seconds = request["grantTTLSeconds"].number ?? 3600
                duration = seconds.isFinite && seconds > 0 && seconds < Double(Int.max) ? String(Int(seconds)) : "3600"
            }
        }
    }
    private func submit(deny: Bool) {
        busy = true; error = nil
        Task {
            do {
                guard connection == workspace.connectionID, !resolved else { throw DiscoboxError("The connection or request changed. Reopen it from the inbox.") }
                var body: [String: JSONValue] = [:]
                let action = deny ? "deny" : (refresh ? "refresh" : "approve")
                if !deny {
                    if refresh {
                        guard !value.isEmpty else { throw DiscoboxError("Enter the replacement token.") }
                        body = ["value": .string(value), "via": .string("entered")]
                    } else {
                        // Automatic deliberately omits grantTTLSeconds. Sending the
                        // request's duration explicitly bypasses its bounded default.
                        body.merge(try ApprovalDuration.fields(duration, kind: item.kind, maximum: credentialMaximum)) { _, new in new }
                        if item.kind == "trust" {
                            guard let i = Int(pin), certificates.indices.contains(i) else { throw DiscoboxError("Choose the certificate to trust.") }
                            let cert = certificates[i], ca = cert["isCA"] == .bool(true)
                            body["pin"] = .object(["kind": .string(ca ? "ca" : "leaf-spki"), "sha256": cert[ca ? "sha256" : "spkiSha256"]])
                        } else {
                            if !secret.isEmpty { body["secretId"] = .string(secret) }
                            if request["policy"] != .null { body["policy"] = request["policy"] }
                            if rule {
                                guard request["policy"] != .null else { throw DiscoboxError("This request has no policy for an auto-approval rule.") }
                                guard let days = Double(ruleDays), days > 0, days.isFinite else { throw DiscoboxError("Enter a positive rule lifetime.") }
                                let repos = repositories.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                guard everyBox || !repos.isEmpty else { throw DiscoboxError("Choose repositories or explicitly select every box.") }
                                var r: [String: JSONValue] = ["policy": request["policy"], "expiresAt": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(days * 86400)))]
                                if everyBox { r["everyDiscobox"] = .bool(true) } else { r["repositories"] = .array(repos.map { .string($0) }) }
                                body["rule"] = .object(r)
                            }
                            if changeSecret {
                                guard let maximum = Int(limit), maximum >= 0 else { throw DiscoboxError("Invalid credential limit.") }
                                body["secretHost"] = .string(host); body["secretMaxGrantTTLSeconds"] = .number(Double(maximum))
                            }
                            if newCredential {
                                guard !value.isEmpty, !newName.isEmpty else { throw DiscoboxError("Enter a name and token value.") }
                                guard let seconds = Int(duration), seconds >= 0 else { throw DiscoboxError("Choose a duration for the new credential.") }
                                let made = try await workspace.operation(.createSecret, payload: .object(["name": .string(newName), "type": .string("token"), "host": .string(host), "value": .object(["token": .string(value)]), "maxGrantTTLSeconds": .number(Double(seconds))]))
                                guard connection == workspace.connectionID else { throw DiscoboxError("The credential was created on the previous connection; approval was not sent.") }
                                secret = made["id"].string
                                guard !secret.isEmpty else { throw DiscoboxError("Credential may have been created; refresh before retrying.") }
                                newCredential = false; value = ""
                            }
                            if !secret.isEmpty { body["secretId"] = .string(secret) }
                        }
                    }
                }
                try await workspace.answer(item, action: action, payload: .object(body), onAccepted: {
                    value = ""; busy = false
                    if !closed { close() }
                })
                if !closed { busy = false }
            } catch {
                busy = false
                if !closed { self.error = error.localizedDescription }
                else if connection == workspace.connectionID { workspace.commandError = item.title + ": " + error.localizedDescription }
                await workspace.refreshApprovals()
            }
        }
    }
}
