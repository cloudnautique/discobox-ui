import SwiftUI
import AppKit
import DiscoboxCore

struct AppearanceSettings: View {
    @AppStorage("inspectorCompactRail") private var compactRail = true
    var body: some View {
        Form {
            Section("Inspector") {
                Picker("When inspector is collapsed", selection: $compactRail) {
                    Text("Show compact rail").tag(true)
                    Text("Hide completely").tag(false)
                }
                Text("The compact rail keeps the selected box’s services one click away. Change Toggle Inspector in Keybindings to customize its shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct WorkspaceInspector: View {
    let box: Sandbox
    @Environment(WorkspaceCommands.self) private var commands
    var body: some View {
        @Bindable var commands = commands
        VStack(spacing: 0) {
            HStack {
                Picker("Inspector section", selection: $commands.inspectorSection) {
                    Text("Services").tag("services")
                    Text("Box").tag("box")
                    Text("Tags").tag("tags")
                }.pickerStyle(.segmented)
            }.padding(10)
            Divider()
            switch commands.inspectorSection {
            case "box": BoxInspector(box: box)
            case "tags":
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tags").font(.headline)
                        let tags = box.meta?.tags ?? [:]
                        if tags.isEmpty { Text("No tags on this box.").foregroundStyle(.secondary) }
                        ForEach(tags.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) {
                                Image(systemName: "tag").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key).fontWeight(.medium)
                                    if let value = tags[key], !value.isEmpty {
                                        Text(value).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 0)
                            }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Text("Use Filter by tag in the boxes menu to narrow your list.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            default: ServicesView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServiceRail: View {
    let box: Sandbox
    @Environment(Workspace.self) private var workspace
    @Environment(WorkspaceCommands.self) private var commands
    @Environment(ServiceForwards.self) private var forwards
    @Environment(DesktopWindows.self) private var desktops
    @State private var session: ServiceForwardSession?
    private var live: Bool { box.isRunning && !workspace.pendingBoxActions.contains(box.id) }
    var body: some View {
        HStack(spacing: 0) {
            Divider()
            VStack(spacing: 10) {
                Button { commands.toggleInspector() } label: { Image(systemName: "sidebar.right") }
                    .help("Expand inspector (" + commands.appShortcuts[.toggleInspector] + ")")
                    .padding(.top, 12)
                Divider().padding(.horizontal, 8)
                ScrollView {
                    VStack(spacing: 12) {
                        if session?.loading == true { ProgressView().controlSize(.mini) }
                        if let error = session?.error {
                            Button { commands.openServices() } label: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }.help(error)
                        }
                        ForEach(session?.ports ?? []) { port in
                            Button { open(port) } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: port.isDesktop ? "desktopcomputer" : port.protocol == "udp" ? "network" : "globe")
                                        .font(.system(size: 15))
                                    if !port.isDesktop { Text(String(port.port)).font(.system(size: 9, design: .monospaced)) }
                                }.frame(width: 44, height: 36).contentShape(Rectangle())
                            }
                            .disabled(!live || workspace.isDemo)
                            .help("\(port.serviceName.isEmpty ? "Port \(port.port)" : port.serviceName)\n\(port.protocol.uppercased()) · \(port.port) → \(port.address)")
                            .accessibilityLabel(port.isDesktop ? "Open desktop" : "Open \(port.serviceName), port \(port.port)")
                            .contextMenu {
                                if port.browserURL(as: "http") != nil {
                                    Button("Open as HTTP") { open(port, scheme: "http") }
                                    Button("Open as HTTPS") { open(port, scheme: "https") }
                                    Divider()
                                }
                                Button("Copy Address") { copy(port) }
                            }
                        }
                    }.padding(.vertical, 4)
                }
                Spacer(minLength: 0)
            }.frame(width: 52)
        }.background(.bar)
        .buttonStyle(.borderless)
        .task(id: live) {
            session = live ? forwards.session(box: box.id, workspace: workspace) : nil
        }
    }
    private func copy(_ port: ServicePort) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(port.browserURL?.absoluteString ?? port.address, forType: .string)
    }
    private func open(_ port: ServicePort, scheme: String? = nil) {
        guard live, !workspace.isDemo else { return }
        guard let url = scheme.flatMap({ port.browserURL(as: $0) }) ?? port.browserURL ?? port.browserURL(as: "http") else {
            copy(port); return
        }
        if port.isDesktop { desktops.open(url: url, box: box) }
        else { NSWorkspace.shared.open(url) }
    }
}
