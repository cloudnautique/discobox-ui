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
    @State private var reviewExpanded: Bool

    init(initiallyExpanded: Bool = false) {
        _reviewExpanded = State(initialValue: initiallyExpanded)
    }

    private var canReview: Bool {
        !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy
    }

    var body: some View {
        StudioConfirmation(title: "Tools & review", symbol: "wrench.and.screwdriver",
                           subtitle: workspace.selectedBox?.displayName, width: 620) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Box tools", detail: "Open a tool beside your agent.")
                        toolList
                    }
                    advancedReview
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Additional session", detail: "Keep your current agent and open another session in this box.")
                        Button { launch(nil) } label: {
                            actionRow(title: "Open another agent session", detail: "Uses this box’s harness and working directory.", symbol: "sparkles")
                        }.buttonStyle(ToolsActionStyle()).studioCard().disabled(busy)
                    }
                }.padding(1)
            }.frame(maxHeight: .infinity)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(.top, 12)
            }
        } footer: {
            HStack {
                if busy { ProgressView("Opening session…").controlSize(.small).font(.caption) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }.frame(height: 640).interactiveDismissDisabled(busy)
        .task {
            defer { loading = false }
            do { tools = try await workspace.operation(.tools)["tools"].array }
            catch { self.error = error.localizedDescription }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var toolList: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView("Loading tools…").controlSize(.small).frame(maxWidth: .infinity).padding(24)
            } else if tools.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 20)).foregroundStyle(.secondary)
                    Text("No tools available").font(.system(size: 12, weight: .medium))
                    Text("Tools reported by this box appear here.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(24)
            } else {
                ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                    if index > 0 { Divider().overlay(DiscoboxAppearance.border).padding(.leading, 52) }
                    toolButton(tool)
                }
            }
        }.studioCard()
    }

    private func toolButton(_ tool: JSONValue) -> some View {
        let problem = tool["problem"].string
        let supported = tool["runs"].string == "sandbox"
        return Button { launch(tool["id"].string) } label: {
            actionRow(title: tool["name"].string, detail: tool["description"].string,
                      symbol: tool["id"].string == "ai.discobox.diff" ? "arrow.triangle.branch" : "wrench.and.screwdriver",
                      problem: problem.isEmpty && !supported ? "This tool cannot run in this box." : problem)
        }.buttonStyle(ToolsActionStyle()).disabled(busy || !supported || !problem.isEmpty)
    }

    private func actionRow(title: String, detail: String, symbol: String, problem: String = "") -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(DiscoboxAppearance.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                if !problem.isEmpty { Text(problem).font(.system(size: 11)).foregroundStyle(.orange) }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private var advancedReview: some View {
        DisclosureGroup(isExpanded: $reviewExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                StudioConfirmationField(title: "Base ref or SHA") {
                    TextField("main", text: $base).accessibilityIdentifier("tools.base")
                }
                StudioConfirmationField(title: "Head ref or SHA") {
                    TextField("feature-branch", text: $head).accessibilityIdentifier("tools.head")
                }
                Text("Both refs must be available in this box. Review comments stay in its repository.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Open review") { launch("ai.discobox.diff", refs: true) }
                        .buttonStyle(.borderedProminent).disabled(!canReview)
                        .accessibilityIdentifier("tools.openReview")
                }
            }.padding(.top, 14).disabled(busy)
        } label: {
            sectionTitle("Advanced review", detail: "Compare commits, branches or pull-request refs.")
        }.padding(14).studioCard().accessibilityIdentifier("tools.advancedReview")
    }

    private func launch(_ tool: String?, refs: Bool = false) {
        busy = true; error = nil
        Task {
            do {
                try await workspace.openSession(tool: tool,
                    base: refs ? base.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                    head: refs ? head.trimmingCharacters(in: .whitespacesAndNewlines) : "")
                dismiss()
            }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct ToolsActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? 1 : 0.5)
            .background(configuration.isPressed ? DiscoboxAppearance.selection : Color.clear)
    }
}
