import SwiftUI
import AppKit
import DiscoboxCore

struct ServicesView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(ServiceForwards.self) private var forwards
    @Environment(DesktopWindows.self) private var desktops
    @State private var session: ServiceForwardSession?
    private var live: Bool { workspace.selectedBox?.isRunning == true && !workspace.pendingBoxActions.contains(workspace.sandboxID ?? "") }
    private var declaredServices: [Service] {
        workspace.services.filter { service in
            service.id != "ai.discobox.desktop" || session?.ports.contains(where: \.isDesktop) != true
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !live {
                    Text("Saved service state. Start this box to open its ports.").font(.callout).foregroundStyle(.secondary)
                }
                if let session {
                    if session.loading { ProgressView("Finding ports…") }
                    if let error = session.error {
                        Text(error).foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                        Button("Reconnect ports") { reconnect() }.disabled(!live)
                    }
                    let desktop = session.ports.filter(\.isDesktop)
                    if !desktop.isEmpty {
                        serviceHeading("Desktop", symbol: "desktopcomputer")
                        ForEach(desktop) { port in portRow(port) }
                        Divider()
                    }
                }
                ForEach(declaredServices) { service in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(service.name).font(.headline)
                            Spacer()
                            StatusLabel(status: service.status.capitalized)
                        }
                        if let description = service.description, !description.isEmpty {
                            Text(description).font(.callout).foregroundStyle(.secondary)
                        }
                        let ports = session?.ports.filter { $0.serviceId == service.id && !$0.isDesktop } ?? []
                        ForEach(ports) { port in portRow(port) }
                        let missing = (service.ports ?? []).filter { number in !(session?.ports.contains { $0.port == number } ?? false) }
                        if !missing.isEmpty {
                            Text("Declared ports: " + missing.map(String.init).joined(separator: ", ") + " · not forwarded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let problem = service.problem ?? service.error, !problem.isEmpty {
                            Text(problem).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Divider()
                }
                let discovered = session?.ports.filter { port in !port.isDesktop && !workspace.services.contains { $0.id == port.serviceId } } ?? []
                if !discovered.isEmpty {
                    serviceHeading("Other ports", symbol: "network")
                    ForEach(discovered) { port in portRow(port) }
                }
                if workspace.services.isEmpty && session?.ports.isEmpty != false && session?.loading != true {
                    Text("No services or ports reported.").foregroundStyle(.secondary)
                }
                Text("Desktop opens in the app. Other web ports open in your browser. Other ports provide a local address to copy. Forwards stay available while this app is connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: live) {
            if live, let box = workspace.sandboxID { session = forwards.session(box: box, workspace: workspace) }
            else { session = nil }
        }
    }
    private func serviceHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline)
    }
    private func portRow(_ port: ServicePort) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !port.serviceName.isEmpty && !workspace.services.contains(where: { $0.id == port.serviceId }) && !port.isDesktop {
                Text(port.serviceName).font(.subheadline.weight(.medium))
            }
            HStack {
                Text("\(port.port) · \(port.protocol.uppercased())").font(.system(.callout, design: .monospaced))
                Spacer()
                if let url = port.browserURL {
                    Button {
                        if port.isDesktop, let box = workspace.selectedBox { desktops.open(url: url, box: box) }
                        else { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(port.isDesktop ? "Open Desktop" : "Open", systemImage: "arrow.up.right.square")
                    }.disabled(!live || workspace.isDemo)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(port.browserURL?.absoluteString ?? port.address, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy local address")
            }
            Text(port.browserURL?.absoluteString ?? port.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private func reconnect() {
        guard let box = workspace.sandboxID else { return }
        desktops.close(box: box)
        forwards.close(box: box)
        session = forwards.session(box: box, workspace: workspace)
    }
}
