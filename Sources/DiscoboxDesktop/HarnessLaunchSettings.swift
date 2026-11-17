import SwiftUI
import AppKit
import DiscoboxCore

struct HarnessLaunchSettings: View {
    let harness: Harness
    let connection: ConnectionStore
    @AppStorage("harnessLaunchDefaults.v1") private var stored = "{}"
    private var key: String { HarnessLaunchDefaults.key(computer: connection.endpointLabel, project: connection.projectID ?? "", harness: harness.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEW BOX DEFAULTS").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Discobox API access", isOn: Binding(get: {
                    HarnessLaunchDefaults.enabled(stored, key: key)
                }, set: { stored = HarnessLaunchDefaults.setting(stored, key: key, enabled: $0) }))
                    .disabled(harness.usesLegacySetup || !connection.isConnected)
                    .accessibilityIdentifier("harness.managerDefault")
                Text(harness.usesLegacySetup ? "Update this host’s Discobox server to enable manager access at launch." : "New boxes can act as managers: discover boxes, create children and manage boxes they lead, within Discobox’s permissions. This grants no credential access.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Default in this app for this computer, project and harness. You can override it in New Box. Changing it does not change existing boxes or another account variant.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14).studioCard()
        }
    }
}

/// Check the immutable candidate once per candidate/state/shared revision.
/// No additional polling loop or token values are involved.
struct HarnessChangesBanner: View {
    let box: Sandbox
    let harness: Harness
    let review: () -> Void
    let prompt: () -> Bool
    @Environment(ConnectionSession.self) private var workspace
    @AppStorage("harnessLoginPrompts.v1") private var presented = "[]"
    @State private var model: HarnessManagement?
    @State private var retry = 0
    private var key: String {
        [workspace.connectionState.connectionID.uuidString, box.id, (box.runtime.agentStatus ?? .null)["harnessConfigCandidate"].string,
         (box.runtime.agentStatus ?? .null)["harnessConfigState"].string, (box.harnessConfig ?? .null)["revision"].pretty, String(retry)].joined(separator: "|")
    }
    var body: some View {
        Group {
            if let model, model.canSave {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(DiscoboxAppearance.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.changes["state"].string == "saved-handoff-pending" ? "Shared settings saved · source box update pending" : model.changes["credentials"].array.isEmpty ? "Settings changed in this box" : "Save this login for new boxes")
                            .font(.system(size: 12, weight: .medium))
                        Text(model.changes["state"].string == "saved-handoff-pending" ? "The shared changes are saved. Finish updating this box; you do not need to sign in again." : "Changes in this box are not shared yet. Review and save them to update \(harness.name) on this computer.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(model.changes["state"].string == "saved-handoff-pending" ? "Finish update…" : "Review and save…", action: review)
                        .buttonStyle(.borderless).accessibilityIdentifier("harness.reviewBoxChanges")
                }.padding(.horizontal, 16).padding(.vertical, 10).background(DiscoboxAppearance.chrome)
            } else if model?.error != nil {
                HStack {
                    Text("Could not check shared harness changes").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { retry += 1 }.font(.caption)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(DiscoboxAppearance.chrome)
            }
        }.task(id: key) {
            let current = HarnessManagement(connection: workspace.connectionState, inventory: workspace.inventory, service: workspace.harnessService, sourceBoxID: workspace.selection.sandboxID, harnessID: harness.id)
            model = current; current.selectBox(box.id)
            await current.refreshPreview(includeSharedDetails: false)
            if !Task.isCancelled { offerLoginReview() }
        }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            offerLoginReview()
        }.onDisappear { model?.close() }
    }

    private func offerLoginReview() {
        guard NSApp.isActive, let model, model.canSave, workspace.connectionState.connectionError == nil,
              workspace.selection.sandboxID == box.id,
              let identity = HarnessLoginPrompts.key(preview: model.changes, computer: workspace.connectionState.endpointLabel,
                  project: workspace.connectionState.projectID ?? "", harness: harness.id, box: box.id),
              !HarnessLoginPrompts.contains(identity, in: presented), prompt() else { return }
        presented = HarnessLoginPrompts.recording(identity, in: presented)
    }
}
