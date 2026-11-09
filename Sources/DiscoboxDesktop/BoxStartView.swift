import SwiftUI
import AppKit
import DiscoboxCore

struct BoxStartPrompt: View {
    let intent: BoxStartIntent
    let cancel: () -> Void
    let viewSaved: () -> Void
    let open: () -> Void

    var body: some View {
        StudioConfirmation(title: intent.alreadyRunning ? "Box is running" : "Start this box?", symbol: "play.fill", subtitle: intent.computer) {
            VStack(alignment: .leading, spacing: 12) {
                StudioConfirmationSubject(name: intent.box.displayName)
                Text(intent.alreadyRunning ? "The box is already running. Open it to continue working." : "Start the box to continue working, or view its saved terminal without starting it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let failure = intent.failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if !intent.isCurrent {
                    Text("The computer’s connection or the box changed. Cancel and choose the box again.").font(.callout).foregroundStyle(.orange)
                }
                if intent.working { ProgressView("Starting box…").controlSize(.small) }
            }
        } footer: {
            HStack(spacing: 12) {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(intent.working)
                Spacer()
                if !intent.alreadyRunning {
                    Button("View Saved", action: viewSaved).disabled(intent.working || !intent.isCurrent)
                        .accessibilityIdentifier("boxStart.viewSaved")
                }
                Button(intent.alreadyRunning ? "Open Box" : "Start & Open") {
                    Task { if await intent.start() { open() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!intent.canStart).accessibilityIdentifier("boxStart.confirm")
            }
        }
            .accessibilityIdentifier("boxStart.prompt")
    }
}

/// A selected stopped box remains actionable when sidebar filters hide its row.
struct StoppedBoxBar: View {
    let box: Sandbox
    @Environment(Workspace.self) private var workspace
    @Environment(Connections.self) private var connections: Connections?
    @State private var intent: BoxStartIntent?
    private var starting: Bool { intent?.working == true || box.runtime.displayState == "starting" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if starting { ProgressView().controlSize(.small) }
                else { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(starting ? "Starting box…" : box.status == "Stopped" ? "Box stopped" : "Box · " + box.status)
                        .font(.system(size: 12, weight: .semibold))
                    Text(starting || box.isRepairing
                         ? (box.preparationStatus?.isEmpty == false ? box.preparationStatus! : "Waiting for Discobox to finish preparing this box.")
                         : box.isArchived ? "Restore the box to continue working. Saved terminal output is read-only." : "Saved terminal output is read-only. Start the box to continue working.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if BoxAction.start.isAvailable(for: box) || starting {
                    NativeStartBoxButton {
                        let request = BoxStartIntent(workspace: workspace, box: box,
                            computer: connections?.sessions.first { $0.workspace === workspace }?.profile.displayName ?? workspace.endpointLabel)
                        intent = request
                        Task { _ = await request.start() }
                    }.fixedSize()
                        .disabled(starting || !workspace.isConnected || workspace.pendingBoxActions.contains(box.id) || workspace.clearingPools.contains(box.poolId ?? ""))
                        .accessibilityIdentifier("boxStart.selected")
                }
            }
            if let failure = intent?.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
            .background(DiscoboxAppearance.chrome)
            .overlay(alignment: .bottom) { DiscoboxAppearance.border.frame(height: 1) }
    }
}

/// A native title, action and accessibility identifier remain available even
/// when the terminal takes first responder or the box is outside sidebar filters.
private struct NativeStartBoxButton: NSViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Start Box", target: context.coordinator, action: #selector(Coordinator.start))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier("boxStart.selected")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        button.contentTintColor = NSColor(DiscoboxAppearance.accent)
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func start() { action() }
    }
}
