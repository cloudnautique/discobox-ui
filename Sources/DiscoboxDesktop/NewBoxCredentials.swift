import SwiftUI
import DiscoboxCore

struct LaunchCredentialDraft: Identifiable {
    let id = UUID()
    var environment = ""
    var host = ""
    var token = ""
    var credential: LaunchCredential { .init(environment: environment, host: host, value: token) }
}

struct NewBoxCredentialsSection: View {
    @Binding var drafts: [LaunchCredentialDraft]
    @State private var expanded = false

    init(drafts: Binding<[LaunchCredentialDraft]>, initiallyExpanded: Bool = false) {
        _drafts = drafts
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text("API keys and MCP tokens used by this box. Agent sign-in is managed separately in Settings → Harnesses.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Box secret").font(.system(size: 11, weight: .medium))
                            Spacer()
                            Button {
                                drafts.removeAll { $0.id == draft.id }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Remove secret").accessibilityLabel("Remove secret")
                        }
                        credentialField("Environment variable") {
                            TextField("OBOT_MCP_TOKEN", text: $draft.environment)
                                .font(.system(size: 12, design: .monospaced))
                                .accessibilityIdentifier("newBox.credential.environment")
                        }
                        credentialField("Allowed host") {
                            TextField("mcp.example.com", text: $draft.host)
                                .accessibilityIdentifier("newBox.credential.host")
                        }
                        credentialField("Secret value") {
                            SecureField("Paste token", text: $draft.token)
                                .accessibilityIdentifier("newBox.credential.token")
                        }
                    }
                    .padding(12).background(DiscoboxAppearance.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
                }
                if drafts.count < 16 {
                    Button {
                        drafts.append(.init())
                    } label: { Label(drafts.isEmpty ? "Add secret" : "Add another secret", systemImage: "plus") }
                        .accessibilityIdentifier("newBox.credential.add")
                }
                Text("Use ${VARIABLE} in your MCP headers. Discobox supplies a placeholder and inserts the token for requests to its destination host. Older servers may ask you to approve its first use.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !drafts.isEmpty {
                    Text("Token drafts are cleared when you change computers or close this window.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                Text("Box secrets").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(drafts.isEmpty ? "Optional" : "\(drafts.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(DiscoboxAppearance.chrome, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
    }

    private func credentialField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            content().textFieldStyle(.plain).font(.system(size: 12)).padding(8)
                .background(DiscoboxAppearance.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DiscoboxAppearance.border, lineWidth: 0.5))
        }
    }
}
