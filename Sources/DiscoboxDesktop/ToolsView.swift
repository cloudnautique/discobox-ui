import SwiftUI
import DiscoboxCore

struct ToolsSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var tools: [JSONValue] = []
    @State private var busy = false
    @State private var error: String?
    @State private var base = ""
    @State private var head = ""
    @State private var loading = true
    var body: some View {
        StudioConfirmation(title: "Tools & review", symbol: "wrench.and.screwdriver", width: 580) {
            VStack(alignment: .leading, spacing: 14) {
                List {
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                        Button { launch(tool["id"].string) } label: {
                            VStack(alignment: .leading) {
                                Text(tool["name"].string).font(.headline)
                                Text(tool["description"].string).foregroundStyle(.secondary)
                                if !tool["problem"].string.isEmpty { Text(tool["problem"].string).foregroundStyle(.orange) }
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain).disabled(busy || tool["runs"].string != "sandbox" || !tool["problem"].string.isEmpty)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).studioCard()
                    .overlay {
                        if loading { ProgressView("Loading tools…").controlSize(.small) }
                        else if tools.isEmpty { ContentUnavailableView("No tools available", systemImage: "wrench.and.screwdriver", description: Text("Tools reported by this box appear here.")) }
                    }
                VStack(alignment: .leading, spacing: 10) {
                        Text("Review commits or pull-request refs").font(.system(size: 12, weight: .semibold))
                        TextField("Base ref or SHA", text: $base)
                        TextField("Head ref or SHA", text: $head)
                        Button("Open review") { launch("ai.discobox.diff", refs: true) }.disabled(base.isEmpty || head.isEmpty || busy)
                        Text("Both refs must be available in this box. Review comments stay in its repository.").font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(12).studioCard()
                Button("Open another agent session") { launch(nil) }.disabled(busy)
                if busy { ProgressView("Opening session…") }
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        } footer: {
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction).disabled(busy) }
        }.frame(height: 600).interactiveDismissDisabled(busy)
        .task {
            defer { loading = false }
            do { tools = try await workspace.operation(.tools)["tools"].array }
            catch { self.error = error.localizedDescription }
        }
    }
    private func launch(_ tool: String?, refs: Bool = false) {
        busy = true; error = nil
        Task {
            do { try await workspace.openSession(tool: tool, base: refs ? base : "", head: refs ? head : ""); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
