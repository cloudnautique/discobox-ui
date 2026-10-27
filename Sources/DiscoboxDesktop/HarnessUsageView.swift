import SwiftUI
import DiscoboxCore

struct HarnessUsageSection: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("harnessUsageExpanded") private var expanded = true
    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    Text("HARNESS USAGE").font(.caption.weight(.semibold))
                    Spacer()
                    if expanded && workspace.usage.isLoading { ProgressView().controlSize(.mini) }
                }.padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Harness usage")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                HarnessUsageContent().padding(.horizontal, 12).padding(.bottom, 12)
            }
        }.tint(DiscoboxAppearance.accent)
    }
}

private struct HarnessUsageContent: View {
    @Environment(Workspace.self) private var workspace
    private var sorted: [Harness] {
        workspace.usage.harnesses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var contentHeight: CGFloat {
        let readings = sorted.compactMap { workspace.usage.snapshots[$0.id] }
        let rows = readings.reduce(0) { $0 + 50 + $1.windows.count * 38 }
        let missing = readings.count < sorted.count ? 28 : 0
        return min(300, max(90, CGFloat(rows + missing + 30)))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sorted.filter { workspace.usage.snapshots[$0.id] != nil }) { harness in
                    if let snapshot = workspace.usage.snapshots[harness.id] {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(alignment: .leading, spacing: 9) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(harness.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(age(snapshot.observedAt, now: context.date))
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
                                        Text(reset(window.resetsAt, now: context.date))
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                            .help(window.resetsAt.map { "Resets \($0.formatted(date: .complete, time: .standard))" } ?? "Reset time unavailable")
                                    }.font(.caption)
                                }
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
                DisclosureGroup("About these readings") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reads recorded quota responses once a minute while this section is expanded. Does not request fresh usage from providers.")
                        ForEach(Array(Set(workspace.usage.notices)).sorted(), id: \.self) { Text($0) }
                    }.font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                }.font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: contentHeight)
        .task(id: workspace.connectionID) {
            while !Task.isCancelled {
                await workspace.refreshUsage()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
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
