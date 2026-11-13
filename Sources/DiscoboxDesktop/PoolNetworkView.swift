import SwiftUI
import DiscoboxCore

struct PoolNetworkView: View {
    let poolID: String
    let computer: String
    let connection: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var pool: JSONValue = .null
    @State private var draft = PoolProxyDraft(proxy: .null)
    @State private var busy = false
    @State private var reviewed = false
    @State private var error: String?
    @State private var message: String?
    private var changedConnection: Bool { workspace.connectionID != connection || !workspace.isConnected }
    private var supported: Bool { pool["outbound"] != .null }
    private var validation: String? { do { _ = try draft.payload(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        StudioConfirmation(title: "Pool network & trust", symbol: "network.badge.shield.half.filled", subtitle: computer + " · " + (pool["name"].string.isEmpty ? poolID : pool["name"].string), width: 720) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if pool != .null {
                        outboundStatus
                        if supported {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Use server defaults", isOn: $draft.defaults)
                                if !draft.defaults {
                                    StudioMenuField(title: "Outbound mode", selection: $draft.mode, options: [
                                        .init(id: "direct", title: "Direct"),
                                        .init(id: "explicit", title: "Explicit proxy"),
                                        .init(id: "inherit", title: "Inherit server proxy environment")
                                    ])
                                    Text(draft.mode == "direct" ? "Connect directly, with this override’s additional trust certificates." : draft.mode == "inherit" ? "Explicitly use the server’s proxy environment, plus additional trust certificates." : "An empty proxy field connects directly for that protocol.").font(.caption).foregroundStyle(.secondary)
                                    if draft.mode == "explicit" {
                                        TextField("HTTP proxy URL", text: $draft.http)
                                        SecureField("HTTP authentication · username:password (optional)", text: $draft.httpCredentials)
                                        Toggle("Clear saved HTTP proxy credentials", isOn: $draft.clearHTTP)
                                        TextField("HTTPS CONNECT proxy URL", text: $draft.https)
                                        SecureField("HTTPS authentication · username:password (optional)", text: $draft.httpsCredentials)
                                        Toggle("Clear saved HTTPS proxy credentials", isOn: $draft.clearHTTPS)
                                        TextField("Bypass list · noProxy", text: $draft.noProxy)
                                        Text("Saved passwords are never returned. Leaving authentication empty preserves them unless you select Clear.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("Additional trusted CA certificates · PEM").font(.caption.weight(.semibold))
                                    TextEditor(text: $draft.caPEM).font(.caption.monospaced()).frame(height: 100).studioCard()
                                }
                                Text("Saving replaces the entire pool override. Server defaults removes it. Sandbox destination policies remain enforced.").font(.callout).foregroundStyle(.secondary)
                                Toggle("I have reviewed this pool’s routing and trust changes", isOn: $reviewed)
                            }.padding(12).studioCard().disabled(busy || changedConnection)
                        } else { Text("This server does not report pool outbound configuration. Update it to configure network routing and trust here.").foregroundStyle(.secondary) }
                    }
                    if changedConnection { Text("This computer reconnected. Close and reopen this pool’s settings.").foregroundStyle(.orange) }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if let validation { Text(validation).foregroundStyle(.orange) }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(2)
            }.frame(height: 460)
        } footer: {
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Reload") { Task { await load() } }.disabled(busy || changedConnection)
                Button("Save changes") { save() }.buttonStyle(.borderedProminent)
                    .disabled(busy || changedConnection || !supported || validation != nil || !reviewed)
            }
        }.task { await load() }
            .onChange(of: draft) { reviewed = false; message = nil }
            .onDisappear { draft.httpCredentials = ""; draft.httpsCredentials = "" }
    }
    private var outboundStatus: some View {
        let status = pool["outbound"]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Effective configuration").font(.headline)
            LabeledContent("Source", value: status["source"].string.isEmpty ? "Not reported" : status["source"].string)
            LabeledContent("Mode", value: status["mode"].string.isEmpty ? "Not reported" : status["mode"].string)
            if !status["http"].string.isEmpty { LabeledContent("HTTP", value: status["http"].string) }
            if !status["https"].string.isEmpty { LabeledContent("HTTPS", value: status["https"].string) }
            if status["restartRequired"] == .bool(true) { Label("Pool restart required to apply this revision", systemImage: "arrow.clockwise").foregroundStyle(.orange) }
            if status["shadowsYaml"] == .bool(true) { Text("This override takes precedence over server.yaml.").font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Desired revision", value: status["desiredRevision"].string.isEmpty ? "Not reported" : status["desiredRevision"].string)
            LabeledContent("Applied revision", value: status["appliedRevision"].string.isEmpty ? "Not reported" : status["appliedRevision"].string)
            if case .object(let contexts) = status["probes"] {
                ForEach(contexts.keys.sorted(), id: \.self) { hop in
                    ForEach(["http", "https"], id: \.self) { scheme in
                        let probe = status["probes"][hop][scheme]
                        LabeledContent(hop + " · " + scheme.uppercased(), value: probe["state"].string.isEmpty ? "Untested" : probe["state"].string)
                        if !probe["detail"].string.isEmpty { Text(probe["detail"].string).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            } else { Text("No hop observations reported. Connectivity has not been verified.").font(.caption).foregroundStyle(.secondary) }
            ForEach(status["caFingerprints"].array.map(\.string), id: \.self) { fingerprint in Text("CA · " + fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).studioCard()
    }
    private func load() async {
        guard !changedConnection else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await workspace.operation(.poolConfiguration, poolID: poolID)
            guard !changedConnection else { return }; pool = result; draft = .init(proxy: result["proxy"]); reviewed = false
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard !changedConnection, !busy, reviewed, let proxy = try? draft.payload() else { return }
        let body: JSONValue = .object(["proxy": proxy, "expectedProxy": pool["proxy"]])
        busy = true; error = nil
        Task {
            defer { busy = false; draft.httpCredentials = ""; draft.httpsCredentials = ""; reviewed = false }
            do {
                let result = try await workspace.operation(.updatePoolProxy, payload: body, poolID: poolID)
                guard !changedConnection else { return }
                pool = result; draft = .init(proxy: result["proxy"])
                message = "Saved. Check the applied revision above. Restart the pool yourself if required; saving does not restart it."
            } catch { self.error = error.localizedDescription }
        }
    }
}
