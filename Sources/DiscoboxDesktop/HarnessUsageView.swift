import SwiftUI
import AppKit
import DiscoboxCore

/// Presentation only: each computer retains its own collector, cadence and
/// harness IDs. Equal harness IDs on different servers never share readings.
@MainActor struct UsageComputer: Identifiable {
    let id: String
    let name: String
    let usage: HarnessUsage
    static func connected(_ connections: Connections) -> [UsageComputer] {
        connections.sessions.filter { $0.connectionState.isConnected }.map {
            .init(id: $0.id, name: $0.profile.displayName, usage: $0.usage)
        }
    }
}

struct HarnessUsageSection: View {
    @Environment(Connections.self) private var connections: Connections
    @AppStorage("harnessUsageExpanded") private var expanded = true
    @AppStorage("harnessUsageShelfHeight") private var height = 150.0
    @GestureState private var resize: ShelfResize?
    @State private var resizeHovered = false
    @State private var showDetails = false
    private var computers: [UsageComputer] { UsageComputer.connected(connections) }
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
                            // The handle moves as the shelf grows. Local drag
                            // coordinates feed that movement back into the next
                            // event and make it oscillate. Keep a global anchor,
                            // and persist only once when the drag finishes.
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .updating($resize) { value, state, transaction in
                                    transaction.animation = nil
                                    let start = state?.start ?? height
                                    state = ShelfResize(start: start, height: min(320, max(120, start - value.translation.height)).rounded())
                                }
                                .onEnded { value in
                                    let start = resize?.start ?? height
                                    var transaction = Transaction(animation: nil)
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        height = min(320, max(120, start - value.translation.height)).rounded()
                                    }
                                })
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
                if expanded && computers.contains(where: { $0.usage.isLoading }) { ProgressView().controlSize(.mini) }
                Button("Details…") { showDetails = true }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 12).frame(height: 34)
            if expanded {
                UsageSummary(computers: computers).equatable().padding(.horizontal, 12).padding(.bottom, 10)
                    .frame(height: min(320, max(120, resize?.height ?? height)))
            }
        }
        .background(DiscoboxAppearance.sidebar)
        .tint(DiscoboxAppearance.accent)
        .sheet(isPresented: $showDetails) { HarnessUsageDetails() }
    }
    private struct ShelfResize {
        let start: Double
        let height: Double
    }
}

/// Cursor rectangles follow the native view's lifetime and geometry, so
/// collapsing the shelf cannot leave a pushed resize cursor behind.
private struct UsageResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = CursorView()
        view.identifier = .init("usage.resizeHandle")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.window?.invalidateCursorRects(for: view) }
    private final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }
}

private struct UsageSummary: View, @MainActor Equatable {
    let computers: [UsageComputer]
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.computers.count == rhs.computers.count && zip(lhs.computers, rhs.computers).allSatisfy {
            $0.id == $1.id && $0.name == $1.name && $0.usage === $1.usage
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(computers) { computer in
                        VStack(alignment: .leading, spacing: 9) {
                            UsageComputerHeading(computer: computer)
                            ComputerUsageSummary(now: context.date).environment(computer.usage)
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
    @Environment(HarnessUsage.self) private var usage
    let now: Date
    private var available: [Harness] { usage.harnesses.filter { usage.snapshots[$0.id] != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(available) { harness in
                if let snapshot = usage.snapshots[harness.id] {
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
                                    .progressViewStyle(StudioQuotaProgressStyle())
                                    .accessibilityLabel("\(harness.name), \(window.title)")
                                Text("\(window.usedPercent, specifier: "%.0f")%")
                                    .font(.caption2).monospacedDigit().frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            if available.isEmpty {
                Text(usage.isLoading ? "Loading usage…" : "No usage readings yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct HarnessUsageDetails: View {
    @Environment(Connections.self) private var connections: Connections
    @Environment(\.dismiss) private var dismiss
    private var computers: [UsageComputer] { UsageComputer.connected(connections) }
    var body: some View {
        StudioConfirmation(title: "Harness usage", symbol: "gauge.with.dots.needle.33percent") {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(computers) { computer in
                            VStack(alignment: .leading, spacing: 12) {
                                UsageComputerHeading(computer: computer)
                                HarnessUsageContent(now: context.date).environment(computer.usage)
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
                                    let notices = Array(Set(computer.usage.notices)).sorted()
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
        } footer: {
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction) }
        }.frame(height: 600)
    }
}

private struct HarnessUsageContent: View {
    @Environment(HarnessUsage.self) private var usage
    let now: Date
    private var sorted: [Harness] {
        usage.harnesses
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sorted.filter { usage.snapshots[$0.id] != nil }) { harness in
                if let snapshot = usage.snapshots[harness.id] {
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
                                        .progressViewStyle(StudioQuotaProgressStyle())
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
            let missing = sorted.filter { usage.snapshots[$0.id] == nil }
            if !missing.isEmpty {
                DisclosureGroup("No readings · \(missing.count)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(missing) { Text($0.name) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if sorted.isEmpty && !usage.isLoading {
                Text("No usage readings available").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func age(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return "Updated just now" }
        return (minutes > 15 ? "Observed " : "Updated ") + ServerDate.relative(date, to: now)
    }
    private func reset(_ date: Date?, now: Date) -> String {
        guard let date else { return "Reset unknown" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting update" }
        if seconds < 86400 {
            return "Resets " + ServerDate.relative(now.addingTimeInterval(max(60, ceil(seconds / 60) * 60)), to: now)
        }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow " + date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
