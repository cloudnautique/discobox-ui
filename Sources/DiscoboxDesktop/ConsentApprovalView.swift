import SwiftUI
import DiscoboxCore

struct ApprovalSheet: View {
    let item: ApprovalItem
    var initialDuration: String? = nil
    var body: some View {
        switch item.kind {
        case "credential" where item.request["use"] != .null || item.request["delegate"] != .null: ScopedCredentialApprovalView(item: item)
        case "credential", "trust": LegacyApprovalSheet(item: item, initialDuration: initialDuration)
        default: ConsentApprovalView(item: item)
        }
    }
}

/// Shared explicit consent for API authority, adoption and token replacement.
/// These are not credential grants and never inherit credential-approval fields.
struct ConsentApprovalView: View {
    let item: ApprovalItem
    @Environment(Workspace.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @Environment(\.dismiss) private var dismiss
    @State private var connection: UUID?
    @State private var value = ""
    @State private var busy = false
    @State private var reviewed = false
    @State private var closed = false
    @State private var error: String?
    private var resolved: Bool { connection != nil && (connection != workspace.connectionID || !workspace.approvals.contains(item)) }
    private var isRefresh: Bool { item.kind == "refresh" }
    private var approveTitle: String { isRefresh ? "Update credential" : item.kind == "apiAccess" ? "Enable API access" : "Allow leadership" }
    var body: some View {
        StudioConfirmation(title: resolved ? "Request no longer pending" : item.title, symbol: isRefresh ? "key" : "checkmark.shield", width: 660) {
            if resolved {
                Text("This request was answered, changed, or withdrawn. Reopen the current inbox if it still needs your attention.").foregroundStyle(.secondary)
            } else {
                ApprovalReview(reviewed: $reviewed, revision: item.request.pretty) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let host = connections?.sessions.first(where: { $0.workspace === workspace }) { LabeledContent("Computer", value: host.profile.displayName) }
                        LabeledContent("Requesting box", value: name(item.boxID))
                        if !item.request["justification"].string.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Reason · from the requesting box").font(.caption).foregroundStyle(.secondary)
                                Text(item.request["justification"].string).textSelection(.enabled)
                            }.padding(12).studioCard()
                        }
                        details
                        DisclosureGroup("Request details") { Text(item.request.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 370)
                if !reviewed { Text("Read to the end to enable approval.").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if busy { Text("Waiting for Discobox. Closing this window leaves the submitted decision in progress.").font(.caption).foregroundStyle(.secondary) }
            }
        } footer: {
            HStack {
                Button(resolved || busy ? "Close" : "Later", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if !resolved && item.supported {
                    Button(approveTitle) { submit(approve: true) }.buttonStyle(.bordered)
                        .disabled(busy || !reviewed || isRefresh && value.isEmpty)
                        .accessibilityIdentifier("approval.confirmConsent")
                    Button(isRefresh ? "Dismiss request" : "Deny", role: .destructive) { submit(approve: false) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }.onAppear { connection = workspace.connectionID }
            .onDisappear { closed = true; value = "" }
    }
    @ViewBuilder private var details: some View {
        switch item.kind {
        case "apiAccess":
            Text("What enabling API access allows").font(.headline)
            Text("This box can discover boxes and watch project events, and create boxes using project harness configurations within its allowed egress.")
            Text("For boxes it directly leads, it can manage terminals, files, lifecycle, source/settings and services, and answer eligible credential requests within its delegation.")
            Text("Wider-egress children remain read-only. This grants no credential and does not bypass credential or network restrictions. Access stays enabled until a person turns it off.").foregroundStyle(.secondary)
        case "adoption":
            LabeledContent("Box to be led", value: item.request["childName"].string.isEmpty ? name(item.request["childSandboxId"].string) : item.request["childName"].string)
            LabeledContent("Current leader", value: item.request["currentParentSandboxId"].string.isEmpty ? "None" : name(item.request["currentParentSandboxId"].string))
            Text(item.request["readOnly"] == .bool(true)
                 ? "This child has wider network access. Leadership grants read-only access; it does not grant command, file-write or lifecycle authority."
                 : "Leadership permits managing this direct child’s terminals, files, lifecycle, settings and services, subject to its network and credential restrictions.")
            Text("Approving replaces the child’s current leader. It does not grant new credentials.").foregroundStyle(.secondary)
        case "refresh":
            LabeledContent("Credential", value: item.request["secretName"].string.isEmpty ? item.request["secretId"].string : item.request["secretName"].string)
            Text("Replace this project credential’s token value. Other boxes using the same credential will also use the replacement; grant scopes and lifetimes stay as they are.")
            SecureField("New token value", text: $value).textFieldStyle(.roundedBorder)
            Text("The value is sent only to this request’s computer and cleared when this window closes. No refresh command is run automatically.").font(.caption).foregroundStyle(.secondary)
        default:
            Text("This server uses a request type this build cannot answer. Use a compatible Discobox console to review it. The request remains pending.").foregroundStyle(.secondary)
        }
    }
    private func name(_ id: String) -> String { workspace.sandboxes.first { $0.id == id }?.displayName ?? id }
    private func close() { closed = true; value = ""; dismiss() }
    private func submit(approve: Bool) {
        guard !busy, !resolved, connection == workspace.connectionID else { return }
        busy = true; error = nil
        let payload: JSONValue = isRefresh && approve ? .object(["value": .string(value)]) : .object([:])
        Task {
            do {
                try await workspace.validateApproval(item, connection: connection!)
                try await workspace.answer(item, action: approve ? (isRefresh ? "refresh" : "approve") : "deny", payload: payload, onAccepted: {
                    busy = false; value = ""; if !closed { close() }
                })
            } catch {
                busy = false
                if !closed { self.error = error.localizedDescription }
                else if connection == workspace.connectionID { workspace.commandError = error.localizedDescription }
                await workspace.refreshApprovals()
            }
        }
    }
}

/// Approval becomes available only after the current summary has been visible
/// through its end. Denying never requires approving or widening anything first.
struct ApprovalReview<Content: View>: View {
    @Binding var reviewed: Bool
    let revision: String
    @ViewBuilder var content: Content
    @State private var contentHeight = CGFloat.infinity
    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: 0).id("review-top")
                        content
                        Color.clear.frame(height: 1)
                            .background(GeometryReader { geometry in Color.clear.preference(key: ApprovalReviewBottom.self, value: geometry.frame(in: .named("approval-review")).maxY) })
                    }.background(GeometryReader { geometry in Color.clear.preference(key: ApprovalReviewHeight.self, value: geometry.size.height) })
                }.coordinateSpace(name: "approval-review")
                    .onPreferenceChange(ApprovalReviewBottom.self) { end in reviewed = end <= viewport.size.height + 2 }
                    .onPreferenceChange(ApprovalReviewHeight.self) { contentHeight = $0 }
                    .task(id: revision) {
                        reviewed = false
                        reader.scrollTo("review-top", anchor: .top)
                        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                        reviewed = contentHeight <= viewport.size.height + 2
                    }
            }
        }
    }
}
private struct ApprovalReviewBottom: PreferenceKey {
    static let defaultValue = CGFloat.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ApprovalReviewHeight: PreferenceKey {
    static let defaultValue = CGFloat.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
