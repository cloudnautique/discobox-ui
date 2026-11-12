import SwiftUI
import DiscoboxCore

struct CredentialBindingConflictNotice: View {
    let conflicts: [JSONValue]
    let addBeside: () -> Void
    private var delegationOnly: Bool { conflicts.allSatisfy { $0["part"].string == "delegate" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(delegationOnly ? "Existing delegation cannot be replaced" : "Existing access cannot be replaced", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DiscoboxAppearance.activityAttention)
            if let first = conflicts.first { Text(first["message"].string).font(.caption).foregroundStyle(.secondary) }
            if conflicts.contains(where: { $0["canAdd"] == .bool(true) }) {
                Button("Keep existing access and add requested use", action: addBeside)
                    .font(.system(size: 12, weight: .medium)).buttonStyle(.borderless)
                    .accessibilityIdentifier("approval.addBesideExisting")
                Text("Changes the draft to an additional scoped grant. Review its effect before applying.").font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("Affected bindings (\(conflicts.count))") {
                ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conflict["part"].string == "delegate" ? "Share with child boxes" : "Use in this box").font(.caption.weight(.medium))
                        Text(conflict["bindingId"].string + " · parent " + conflict["parentId"].string).font(.caption2.monospaced()).textSelection(.enabled)
                        Text(conflict["message"].string).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.font(.caption)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).studioCard()
    }
}
