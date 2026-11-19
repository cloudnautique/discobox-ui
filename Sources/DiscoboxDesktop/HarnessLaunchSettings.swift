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
struct HarnessChangesControl: View {
    let box: Sandbox
    let harness: Harness
    let window: NSWindow?
    let review: () -> Void
    @Environment(ConnectionSession.self) private var workspace
    @AppStorage(HarnessLoginPrompts.defaultsKey) private var history = HarnessLoginPrompts()
    @State private var model: HarnessManagement?
    @State private var sheet: NSAlert?
    @State private var retry = 0
    private var reportedCandidate: String { box.runtime.agentStatus?["harnessConfigCandidate"].string ?? "" }
    private var scope: HarnessLoginPrompts.Scope? {
        .init(computer: workspace.connectionState.endpointLabel, project: box.projectId, harness: harness.id, box: box.id)
    }
    private var key: [String] {
        [workspace.connectionState.connectionID.uuidString, box.id, harness.id, reportedCandidate,
         (box.runtime.agentStatus ?? .null)["harnessConfigState"].string, (box.harnessConfig ?? .null)["revision"].pretty,
         scope.flatMap { history.completedCandidate($0) } == reportedCandidate ? "completed" : "open", String(retry)]
    }
    private func isCurrent(_ model: HarnessManagement) -> Bool {
        guard model.validConnection, model.boxID == box.id, model.harnessID == harness.id,
              workspace.connectionState.connectionError == nil, let selected = workspace.selection.selectedBox,
              selected.isRunning, selected.id == box.id, selected.config.harnessConfigId == harness.id,
              selected.runtime.agentStatus?["harnessConfigCandidate"].string == reportedCandidate else { return false }
        return !reportedCandidate.isEmpty && model.changes["candidateId"].string == reportedCandidate
    }
    var body: some View {
        HStack(spacing: 0) {
            if let model, model.canSave, isCurrent(model), let scope {
                let handoff = model.changes["state"].string == "saved-handoff-pending"
                if handoff || history.completedCandidate(scope) != reportedCandidate {
                    Button(handoff ? "Finish update…" : "Review harness changes…") {
                        guard isCurrent(model), model.canSave else { return }
                        if !handoff { history.offered(scope) }
                        review()
                    }
                        .lineLimit(1).buttonStyle(.borderless)
                        .help(handoff ? "Finish applying the saved harness changes to this box" : "Review this box’s changes to the shared \(harness.name) harness")
                        .accessibilityIdentifier("harness.reviewBoxChanges")
                }
            } else if let model, !model.busy,
                      model.error != nil || ["initializing", "unavailable"].contains(model.changes["state"].string) ||
                      (model.canSave && model.changes["candidateId"].string != reportedCandidate) {
                Button("Retry harness check") { retry += 1 }.buttonStyle(.borderless)
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

    private func offerReview() {
        guard let model, isCurrent(model), model.canSave, model.changes["state"].string == "pending",
              let scope else { return }
        if history.hasOffered(scope, candidate: reportedCandidate) {
            // Promote a matching v1 candidate to the current pending episode.
            if history.completedCandidate(scope) == nil {
                var updated = history
                updated.offered(scope)
                if updated != history { history = updated }
            }
            return
        }
        guard NSApp.isActive, let window, window.isKeyWindow, window.attachedSheet == nil, sheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Update the \(harness.name) harness?"
        alert.informativeText = "Changes in “\(box.sidebarTitle)” are local to that box. If you save them, new boxes using \(harness.name) in this project will start with the setup you reviewed. Choose Later to review these changes from the agent header."
        alert.addButton(withTitle: "Review changes…").keyEquivalent = ""
        alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        // A Return intended for the terminal must not act on this sheet.
        alert.window.defaultButtonCell = nil
        sheet = alert
        alert.beginSheetModal(for: window) { response in
            guard sheet === alert else { return }
            sheet = nil
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                guard self.isCurrent(model), model.canSave else { return }
                review()
            }
        }
        history.offered(scope)
    }

    private func dismissOffer() {
        guard let alert = sheet else { return }
        sheet = nil
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
    }
}
