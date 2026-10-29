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
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Needs your attention").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                if let error = workspace.approvalError { Notice(text: "Inbox refresh failed: " + error, symbol: "wifi.exclamationmark") }
                List(requests) { item in
                    Button { selected = item } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(item.title, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                            Text(item.request["justification"].string).lineLimit(3).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }.overlay { if requests.isEmpty { ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle") } }
            }.padding(20).frame(width: 620, height: 460)
        }
    }
}

struct ApprovalSheet: View {
    @Environment(Connections.self) private var connections: Connections?
    let item: ApprovalItem
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var connection: UUID?
    @State private var secrets: [JSONValue] = []
    @State private var secret = ""
    @State private var duration = "3600"
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
    private var request: JSONValue { item.request }
    private var refresh: Bool { request["reason"].string == "refresh" }
    private var resolved: Bool { !workspace.approvals.contains { $0.id == item.id } }
    private var certificates: [JSONValue] { request["observedChain"].array + (request["suppliedCA"] == .null ? [] : [request["suppliedCA"]]) }
    private var selectedSecret: JSONValue { secrets.first { $0["id"].string == secret } ?? .null }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title).font(.title2.bold())
            if resolved { Label("This request was answered elsewhere.", systemImage: "checkmark.circle") }
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
                                if let max = selectedSecret["maxGrantTTLSeconds"].number { Text(max == 0 ? "Credential permits non-expiring grants." : "Credential grant limit: \(Int(max)) seconds.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Section("Duration") {
                            Picker("Preset", selection: $duration) {
                                Text("15 minutes").tag("900"); Text("1 hour").tag("3600"); Text("8 hours").tag("28800"); Text("1 day").tag("86400")
                                if item.kind != "trust" { Text("Never expires").tag("0") }
                                if !["900", "3600", "28800", "86400", "0"].contains(duration) { Text("Custom").tag(duration) }
                            }
                            TextField("Duration in seconds", text: $duration)
                            if let wanted = request["grantTTLSeconds"].number { Text("Requested: \(Int(wanted)) seconds").font(.caption) }
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
                }.formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(refresh ? "Update credential" : "Approve") { submit(deny: false) }
                    .buttonStyle(.bordered).disabled(busy || resolved)
                Button("Deny", role: .destructive) { submit(deny: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(busy || resolved)
            }
        }.padding(20).frame(width: 660, height: 700).interactiveDismissDisabled(busy)
        .task {
            connection = workspace.connectionID
            duration = String(Int(request["grantTTLSeconds"].number ?? 3600))
            newName = request["name"].string
            do { if item.kind == "credential" { secrets = try await workspace.approvalSecrets() } }
            catch { self.error = error.localizedDescription }
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
                        guard let seconds = Int(duration), seconds >= 0, item.kind != "trust" || (seconds > 0 && seconds <= 2592000) else { throw DiscoboxError("Enter a valid duration. Trust must expire within 30 days.") }
                        body["grantTTLSeconds"] = .number(Double(seconds))
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
                try await workspace.answer(item, action: action, payload: .object(body))
                value = ""; dismiss()
            } catch { self.error = error.localizedDescription; await workspace.refreshApprovals() }
            busy = false
        }
    }
}
