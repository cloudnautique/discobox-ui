import SwiftUI
import DiscoboxCore

struct BoxActionRequest: Identifiable {
    let id = UUID()
    let box: Sandbox
    let action: BoxAction
    let connection: UUID
}

struct BoxActionMenu: View {
    let box: Sandbox
    let choose: (BoxAction) -> Void
    @Environment(Workspace.self) private var workspace
    var body: some View {
        ForEach(BoxAction.allCases.filter { $0.isAvailable(for: box) }) { action in
            Button(role: action == .purge ? .destructive : nil) { choose(action) } label: {
                Label(action.title + "…", systemImage: action.symbol)
            }.disabled(workspace.pendingBoxActions.contains(box.id))
        }
    }
}

struct BoxActionSheet: View {
    let request: BoxActionRequest
    @Environment(Workspace.self) private var workspace
    @Environment(TerminalStore.self) private var terminals
    @Environment(ServiceForwards.self) private var forwards
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("\(request.action.title) box", systemImage: request.action.symbol).font(.title2.bold())
            Text(request.box.displayName).font(.headline).textSelection(.enabled)
            Text(request.action.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if request.action == .rename {
                TextField("Box name", text: $name).textFieldStyle(.roundedBorder)
            }
            if request.action == .purge {
                TextField("Type DELETE to permanently delete", text: $confirmation).textFieldStyle(.roundedBorder)
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(working ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(request.action.title, role: request.action == .purge ? .destructive : nil) {
                    working = true; failure = nil
                    Task {
                        do {
                            try await workspace.performBoxAction(request.action, boxID: request.box.id, connection: request.connection, name: name) {
                                if [.stop, .archive, .purge, .upgrade, .repair].contains(request.action) {
                                    terminals.closeBox(request.box.id, connection: request.connection)
                                    forwards.close(box: request.box.id)
                                }
                            }
                            dismiss()
                        } catch {
                            failure = error.localizedDescription + " Check the box’s current state before trying again."
                            working = false
                        }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(working || request.connection != workspace.connectionID || (request.action == .purge && confirmation != "DELETE") || (request.action == .rename && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 128)))
            }
        }.padding(24).frame(width: 440)
            .onAppear { name = request.box.displayName }
            .interactiveDismissDisabled(working)
    }
}
