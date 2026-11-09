import SwiftUI
import AppKit
import DiscoboxCore

struct HarnessSavedFiles: View {
    let title: String
    let files: [JSONValue]
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    DisclosureGroup {
                        HarnessReadOnlyConfigText(text: file["content"].string)
                            .frame(height: 180).background(DiscoboxAppearance.surface, in: RoundedRectangle(cornerRadius: 4))
                    } label: {
                        Text(file["path"].string).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(file["path"].string)
                    }
                }
            }.padding(.top, 10)
        } label: {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(files.isEmpty ? "None" : "\(files.count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }.disabled(files.isEmpty).padding(14)
    }
}

struct HarnessFileChangeView: View {
    let file: JSONValue
    @State private var expanded = false
    @State private var diff: HarnessConfigurationDiff?
    init(file: JSONValue, initiallyExpanded: Bool = false) {
        self.file = file; _expanded = State(initialValue: initiallyExpanded)
    }
    private var before: String { file["previous"]["content"].string }
    private var after: String { file["file"]["content"].string }
    private var status: String {
        if file["remove"] == .bool(true) { return file["file"] == .null ? "Removed" : "Restores baseline" }
        return file["previous"] == .null ? "Added" : "Modified"
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if file["shadowed"] == .bool(true) {
                    Label("A personal override stays active above this saved file.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                if let diff {
                    if diff.usesFullText {
                        Text("Large file · full versions shown to keep review responsive.").font(.caption).foregroundStyle(.secondary)
                        fullVersion("Current", content: before)
                        fullVersion("Proposed", content: after)
                    } else {
                        HStack(spacing: 14) {
                            Text("− Removed").foregroundStyle(DiscoboxAppearance.danger)
                            Text("+ Added").foregroundStyle(DiscoboxAppearance.success)
                        }.font(.system(size: 10))
                        ScrollView([.horizontal, .vertical]) {
                            Text(diffText(diff)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.frame(height: min(300, max(100, CGFloat(diff.lines.count) * 17 + 20)))
                            .background(DiscoboxAppearance.surface, in: RoundedRectangle(cornerRadius: 4))
                    }
                } else { ProgressView("Preparing comparison…").controlSize(.small) }
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 12) {
                Text(file["path"].string).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(file["path"].string)
                Spacer(minLength: 8)
                Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(status == "Removed" ? DiscoboxAppearance.danger : Color.secondary)
            }
        }
        .task(id: expanded) {
            guard expanded, diff == nil else { return }
            let old = before, new = after
            let comparison = await Task.detached(priority: .userInitiated) { HarnessConfigurationDiff(before: old, after: new) }.value
            guard !Task.isCancelled else { return }
            diff = comparison
        }
    }
    private func fullVersion(_ title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            HarnessReadOnlyConfigText(text: content).frame(height: 180)
                .background(DiscoboxAppearance.surface, in: RoundedRectangle(cornerRadius: 4))
        }
    }
    private func diffText(_ diff: HarnessConfigurationDiff) -> AttributedString {
        var result = AttributedString()
        for line in diff.lines {
            let old = line.before.map(String.init) ?? ""
            let new = line.after.map(String.init) ?? ""
            var numbers = AttributedString(old.padding(toLength: 4, withPad: " ", startingAt: 0) + " " + new.padding(toLength: 4, withPad: " ", startingAt: 0) + " ")
            numbers.foregroundColor = .secondary
            result.append(numbers)
            let marker = line.kind == .removed ? "− " : line.kind == .added ? "+ " : "  "
            var text = AttributedString(marker + line.text + "\n")
            if line.kind != .unchanged {
                let color = line.kind == .removed ? DiscoboxAppearance.danger : DiscoboxAppearance.success
                text.foregroundColor = color; text.backgroundColor = color.opacity(0.08)
            }
            result.append(text)
        }
        return result
    }
}

/// Native selectable text keeps large-file inspection read-only and avoids
/// building thousands of SwiftUI rows just to inspect the full versions.
private struct HarnessReadOnlyConfigText: NSViewRepresentable {
    let text: String
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 180))
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.drawsBackground = false; editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text { editor.string = text }
        editor.textColor = .labelColor
    }
}
