import SwiftUI
import AppKit
import DiscoboxCore

/// Presentation only: each computer retains its own collector, cadence and
/// harness IDs. Equal harness IDs on different servers never share readings.
@MainActor struct UsageComputer: Identifiable {
    let id: String
    let name: String
    let workspace: Workspace
    static func connected(_ connections: Connections?, fallback workspace: Workspace) -> [UsageComputer] {
        if let connections {
            return connections.sessions.filter { $0.workspace.isConnected }.map {
                .init(id: $0.id, name: $0.profile.displayName, workspace: $0.workspace)
            }
        }
        return workspace.isConnected ? [.init(id: workspace.connectionID.uuidString, name: "Connected computer", workspace: workspace)] : []
    }
}

struct HarnessUsageSection: View {
    @Environment(Connections.self) private var connections: Connections?
    @Environment(Workspace.self) private var workspace
    @AppStorage("harnessUsageExpanded") private var expanded = true
    @AppStorage("harnessUsageShelfHeight") private var height = 150.0
    @State private var dragHeight: Double?
    @State private var resizeHovered = false
    @State private var showDetails = false
    private var computers: [UsageComputer] { UsageComputer.connected(connections, fallback: workspace) }
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.separator).frame(height: 1)
                .overlay {
                    if expanded {
                        Color.clear.frame(height: 9).contentShape(Rectangle())
                            .overlay {
                                Capsule().fill(.secondary.opacity(resizeHovered ? 0.65 : 0.3))
                                    .frame(width: 28, height: 3).allowsHitTesting(false)
                            }
                            .background(UsageResizeCursor())
                            .onHover { resizeHovered = $0 }
                            .onDisappear { resizeHovered = false }
                            .gesture(DragGesture().onChanged { value in
                                if dragHeight == nil { dragHeight = height }
                                height = min(320, max(120, (dragHeight ?? height) - value.translation.height))
                            }.onEnded { _ in dragHeight = nil })
                            .help("Drag to resize harness usage")
                            .accessibilityLabel("Resize harness usage")
                            .accessibilityAdjustableAction { direction in
                                height = min(320, max(120, height + (direction == .increment ? 20 : -20)))
                            }
                    }
                }
            HStack(spacing: 7) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        Text("Harness usage").font(.system(size: 11, weight: .semibold))
                        Text("\(computers.count) \(computers.count == 1 ? "computer" : "computers")")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Harness usage")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded && computers.contains(where: { $0.workspace.usage.isLoading }) { ProgressView().controlSize(.mini) }
                Button("Details…") { showDetails = true }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 12).frame(height: 34)
            if expanded {
                UsageSummary(computers: computers).padding(.horizontal, 12).padding(.bottom, 10)
                    .frame(height: min(320, max(120, height)))
                    .task(id: workspace.connectionID, priority: .utility) {
                        guard connections == nil else { return }
                        while !Task.isCancelled {
                            await workspace.refreshUsage()
                            do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        }
                    }
            }
        }
        .background(DiscoboxAppearance.sidebar)
        .tint(DiscoboxAppearance.accent)
        .sheet(isPresented: $showDetails) { HarnessUsageDetails().environment(workspace) }
    }
}

/// Cursor rectangles follow the native view's lifetime and geometry, so
/// collapsing the shelf cannot leave a pushed resize cursor behind.
private struct UsageResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ view: NSView, context: Context) { view.window?.invalidateCursorRects(for: view) }
    private final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }
}

private struct UsageSummary: View {
    let computers: [UsageComputer]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(computers) { computer in
                        VStack(alignment: .leading, spacing: 9) {
                            UsageComputerHeading(computer: computer)
                            ComputerUsageSummary(now: context.date).environment(computer.workspace)
                                .padding(.leading, 18)
                        }
                        if computer.id != computers.last?.id { Divider() }
                    }
                    if computers.isEmpty {
                        Text("Connect a computer to see harness usage.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
    }
}

private struct UsageComputerHeading: View {
    let computer: UsageComputer
    var body: some View {
        Label(computer.name, systemImage: "desktopcomputer")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .lineLimit(1).help(computer.name)
            .accessibilityIdentifier("usage.computer." + computer.id)
    }
}

private struct ComputerUsageSummary: View {
    @Environment(Workspace.self) private var workspace
    let now: Date
    private var available: [Harness] { workspace.usage.harnesses.filter { workspace.usage.snapshots[$0.id] != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(available) { harness in
                if let snapshot = workspace.usage.snapshots[harness.id] {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(harness.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if now.timeIntervalSince(snapshot.observedAt) > 900 {
                                Label("Stale", systemImage: "clock").font(.caption2).foregroundStyle(.orange)
                                    .help("Last observed \(snapshot.observedAt.formatted())")
                            }
                        }
                        ForEach(snapshot.windows) { window in
                            HStack(spacing: 8) {
                                Text(window.title == "5-hour window" ? "5h" : window.title == "Weekly" ? "Week" : window.title)
                                    .font(.caption2).foregroundStyle(.secondary).frame(width: 40, alignment: .leading).lineLimit(1)
                                ProgressView(value: window.usedPercent, total: 100)
                                    .tint(window.usedPercent >= 90 ? .orange : DiscoboxAppearance.accent)
                                    .accessibilityLabel("\(harness.name), \(window.title)")
                                Text("\(window.usedPercent, specifier: "%.0f")%")
                                    .font(.caption2).monospacedDigit().frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            if available.isEmpty {
                Text(workspace.usage.isLoading ? "Loading usage…" : "No usage readings yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct HarnessUsageDetails: View {
    @Environment(Connections.self) private var connections: Connections?
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    private var computers: [UsageComputer] { UsageComputer.connected(connections, fallback: workspace) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Harness usage").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(computers) { computer in
                            VStack(alignment: .leading, spacing: 12) {
                                UsageComputerHeading(computer: computer)
                                HarnessUsageContent(now: context.date).environment(computer.workspace)
                                    .padding(.leading, 18)
                            }
                            if computer.id != computers.last?.id { Divider() }
                        }
                        if computers.isEmpty {
                            ContentUnavailableView("No connected computers", systemImage: "network")
                        }
                        DisclosureGroup("About these readings") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Reads recorded quota responses once a minute while connected. Does not request fresh usage from providers. Readings stay separate for each computer and harness.")
                                ForEach(computers) { computer in
                                    let notices = Array(Set(computer.workspace.usage.notices)).sorted()
                                    if !notices.isEmpty {
                                        Text(computer.name).fontWeight(.medium)
                                        ForEach(notices, id: \.self) { Text($0) }
                                    }
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(24).frame(width: 520, height: 600)
        .task(id: workspace.connectionID, priority: .utility) {
            guard connections == nil else { return }
            while !Task.isCancelled {
                await workspace.refreshUsage()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

private struct HarnessUsageContent: View {
    @Environment(Workspace.self) private var workspace
    let now: Date
    private var sorted: [Harness] {
        workspace.usage.harnesses
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sorted.filter { workspace.usage.snapshots[$0.id] != nil }) { harness in
                if let snapshot = workspace.usage.snapshots[harness.id] {
                    VStack(alignment: .leading, spacing: 9) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(harness.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(age(snapshot.observedAt, now: now))
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("Observed \(snapshot.observedAt.formatted(date: .complete, time: .standard))")
                        }
                        ForEach(snapshot.windows) { window in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(window.title == "5-hour window" ? "5 hours" : window.title)
                                        .frame(width: 54, alignment: .leading).lineLimit(1).help(window.title)
                                    ProgressView(value: window.usedPercent, total: 100)
                                        .tint(window.usedPercent >= 90 ? .orange : DiscoboxAppearance.accent)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityLabel("\(window.title), \(Int(window.usedPercent)) percent used")
                                    Text("\(window.usedPercent, specifier: "%.0f")%")
                                        .monospacedDigit().frame(width: 32, alignment: .trailing)
                                }
                                Text(reset(window.resetsAt, now: now))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .help(window.resetsAt.map { "Resets \($0.formatted(date: .complete, time: .standard))" } ?? "Reset time unavailable")
                            }.font(.caption)
                        }
                    }
                }
            }
            let missing = sorted.filter { workspace.usage.snapshots[$0.id] == nil }
            if !missing.isEmpty {
                DisclosureGroup("No readings · \(missing.count)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(missing) { Text($0.name) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if sorted.isEmpty && !workspace.usage.isLoading {
                Text("No usage readings available").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func age(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return "Updated just now" }
        if minutes < 60 { return "\(minutes > 15 ? "Observed" : "Updated") \(minutes)m ago" }
        if minutes < 1440 { return "Observed \(minutes / 60)h ago" }
        return "Observed \(minutes / 1440)d ago"
    }
    private func reset(_ date: Date?, now: Date) -> String {
        guard let date else { return "Reset unknown" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting update" }
        if seconds < 86400 {
            let minutes = max(1, Int(ceil(seconds / 60)))
            return minutes < 60 ? "Resets in \(minutes)m" : "Resets in \(minutes / 60)h \(minutes % 60)m"
        }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow " + date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
