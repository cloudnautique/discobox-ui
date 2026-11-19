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
            Text("NEW BOX DEFAULTS").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
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
    let window: NSWindow?
    let review: () -> Void
    @Environment(ConnectionSession.self) private var workspace
    @AppStorage("harnessSetupSheets.v1") private var presented = "[]"
    @State private var model: HarnessManagement?
    @State private var sheet: NSAlert?
    @State private var retry = 0
    private var reportedCandidate: String { box.runtime.agentStatus?["harnessConfigCandidate"].string ?? "" }
    private var key: String {
        [workspace.connectionState.connectionID.uuidString, box.id, harness.id, reportedCandidate,
         (box.runtime.agentStatus ?? .null)["harnessConfigState"].string, (box.harnessConfig ?? .null)["revision"].pretty, String(retry)].joined(separator: "|")
    }
    private var updateTitle: String { "Update the \(harness.name) harness?" }
    private let updateDescription = "Review the changes from this box. Saving them updates the harness used by new boxes in this project."
    private let reviewTitle = "Review changes…"

    var body: some View {
        VStack(spacing: 0) {
            if let model, model.canSave, model.changes["candidateId"].string == reportedCandidate {
                let handoff = model.changes["state"].string == "saved-handoff-pending"
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(DiscoboxAppearance.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(handoff ? "Shared settings saved · source box update pending" : updateTitle)
                            .font(.callout.weight(.medium))
                        Text(handoff ? "The shared changes are saved. Finish updating this box; you do not need to sign in again." : updateDescription)
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(handoff ? "Finish update…" : reviewTitle, action: review)
                        .buttonStyle(.borderless).accessibilityIdentifier("harness.reviewBoxChanges")
                }.padding(.horizontal, 16).padding(.vertical, 10).background(DiscoboxAppearance.chrome)
            } else if let model, !model.busy,
                      model.error != nil || ["initializing", "unavailable"].contains(model.changes["state"].string) ||
                      (model.canSave && model.changes["candidateId"].string != reportedCandidate) {
                HStack {
                    Text("Could not check shared harness changes").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { retry += 1 }.font(.caption)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(DiscoboxAppearance.chrome)
            }
        }.task(id: key) {
            dismissOffer()
            model?.close()
            let current = HarnessManagement(connection: workspace.connectionState, inventory: workspace.inventory, service: workspace.harnessService, sourceBoxID: workspace.selection.sandboxID, harnessID: harness.id)
            model = current; current.selectBox(box.id)
            await current.refreshPreview(includeSharedDetails: false)
            if !Task.isCancelled { offerReview() }
        }.onChange(of: window) { offerReview() }
        .onChange(of: workspace.connectionState.connectionError) { offerReview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            offerReview()
        }.onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object as? NSWindow === window { Task { @MainActor in offerReview() } }
        }.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
            if note.object as? NSWindow === window { Task { @MainActor in offerReview() } }
        }.onDisappear { model?.close(); dismissOffer() }
    }

    private func identity(for model: HarnessManagement) -> String? {
        guard model.canSave, model.boxID == box.id, model.harnessID == harness.id, workspace.connectionState.connectionError == nil,
              let selected = workspace.selection.selectedBox, selected.isRunning, selected.id == box.id,
              selected.config.harnessConfigId == harness.id else { return nil }
        return HarnessLoginPrompts.key(preview: model.changes,
            reportedCandidate: selected.runtime.agentStatus?["harnessConfigCandidate"].string ?? "",
            computer: workspace.connectionState.endpointLabel, project: workspace.connectionState.projectID ?? "",
            harness: harness.id, box: box.id)
    }

    private func offerReview() {
        guard NSApp.isActive, let window, window.isKeyWindow, window.attachedSheet == nil, sheet == nil,
              let model, let identity = identity(for: model), !HarnessLoginPrompts.contains(identity, in: presented) else { return }
        let alert = NSAlert()
        alert.messageText = updateTitle
        alert.informativeText = "Changes in “\(box.sidebarTitle)” are local to that box. If you save them, new boxes using \(harness.name) in this project will start with the setup you reviewed."
        alert.addButton(withTitle: reviewTitle).keyEquivalent = ""
        alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        // A Return intended for the terminal must not act on this sheet.
        alert.window.defaultButtonCell = nil
        sheet = alert
        alert.beginSheetModal(for: window) { response in
            guard sheet === alert else { return }
            sheet = nil
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                guard self.identity(for: model) == identity else { return }
                review()
            }
        }
        presented = HarnessLoginPrompts.recording(identity, in: presented)
    }

    private func dismissOffer() {
        guard let alert = sheet else { return }
        sheet = nil
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
    }
}
