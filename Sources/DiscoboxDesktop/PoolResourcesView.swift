import SwiftUI
import DiscoboxCore

struct PoolResourcesView: View {
    let computer: String
    var initialPoolID: String? = nil
    @Environment(Workspace.self) private var workspace
    @Environment(TerminalStore.self) private var terminals: TerminalStore?
    @Environment(ServiceForwards.self) private var forwards: ServiceForwards?
    @Environment(DesktopWindows.self) private var desktops: DesktopWindows?
    @Environment(\.dismiss) private var dismiss
    @State private var poolID = ""
    @State private var selection: Set<String> = []
    @State private var sort = "disk"
    @State private var clearRequest: PoolCacheClearRequest?
    @State private var stopping = false
    @State private var actionError: String?
    private var pool: ResourcePool? { workspace.resources.pools.first { $0.id == poolID } }
    private var boxes: [Sandbox] { workspace.sandboxes.filter { $0.poolId == poolID } }
    private var rows: [Sandbox] {
        boxes.sorted { lhs, rhs in
            let l = reading(lhs), r = reading(rhs)
            if l != r { return (l ?? -1) > (r ?? -1) }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
    private var busy: Bool { workspace.clearingPools.contains(poolID) || stopping }
    private var selectedRunning: [Sandbox] { boxes.filter { selection.contains($0.id) && BoxAction.stop.isAvailable(for: $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resources").font(.title2.bold())
                    Text(computer).foregroundStyle(.secondary)
                }
                Spacer()
                if workspace.resources.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { refresh(force: true) }.disabled(workspace.resources.isRefreshing || busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            HStack {
                Picker("Pool", selection: $poolID) {
                    if workspace.resources.pools.isEmpty { Text("No pools available").tag("") }
                    ForEach(workspace.resources.pools) { item in
                        Text(item.name + (item.id == workspace.resources.defaultPoolID ? " (default)" : "")).tag(item.id)
                    }
                }.frame(maxWidth: 430)
                Spacer()
                Picker("Sort by", selection: $sort) {
                    Text("Disk").tag("disk"); Text("CPU").tag("cpu"); Text("Memory").tag("memory")
                }.frame(width: 170)
            }.disabled(busy)
            if let error = workspace.resources.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let pool {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    resourceSummary(pool, now: context.date)
                }
                HStack {
                    Text("Boxes · \(boxes.count)").font(.headline)
                    Spacer()
                    Text("Stopped and archived boxes still occupy disk.").font(.caption).foregroundStyle(.secondary)
                }
                Table(rows, selection: $selection) {
                    TableColumn("Box") { box in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(box.displayName).lineLimit(1)
                            Text(box.status).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }.width(min: 180, ideal: 280)
                    TableColumn("CPU cores") { box in Text(ResourceValue.cpu(box.resourceCPU)).monospacedDigit() }.width(82)
                    TableColumn("Memory") { box in Text(ResourceValue.bytes(box.resourceMemory)).monospacedDigit() }.width(92)
                    TableColumn("Disk") { box in Text(ResourceValue.bytes(box.resourceDisk)).monospacedDigit() }.width(92)
                    TableColumn("Processes") { box in
                        Text(box.isRunning ? box.resourceReport["processCount"].number.map { String(Int(clamping: Int64(min(max($0, 0), 1_000_000_000)))) } ?? "—" : "—")
                    }.width(76)
                }.frame(minHeight: 135)
                if selection.count == 1, let box = boxes.first(where: { selection.contains($0.id) }) {
                    boxDetail(box)
                }
                if let actionError { Text(actionError).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Button(stopping ? "Stopping…" : "Stop Selected") { stopSelected() }
                        .disabled(selectedRunning.isEmpty || busy)
                    Spacer()
                    Button("Clear Caches…", role: .destructive) {
                        clearRequest = .init(pool: pool, connection: workspace.connectionID)
                    }.disabled(busy || !workspace.isConnected)
                        .accessibilityIdentifier("resources.clearCaches")
                }
            } else {
                ContentUnavailableView(workspace.resources.isRefreshing ? "Reading pool resources…" : "No pool resources available", systemImage: "gauge.with.dots.needle.33percent", description: Text("Connect to a computer with a Discobox pool, then refresh."))
            }
        }.padding(22).frame(width: 860, height: 690)
            .interactiveDismissDisabled(busy)
            .onChange(of: poolID) { selection = []; actionError = nil }
            .task(id: workspace.connectionID) {
                let generation = workspace.connectionID
                await workspace.refreshResources()
                guard !Task.isCancelled, generation == workspace.connectionID else { return }
                choosePool()
            }
            .sheet(item: $clearRequest) { request in
                PoolCacheClearSheet(request: request, computer: computer)
            }
    }
    private func reading(_ box: Sandbox) -> Double? {
        switch sort { case "cpu": box.resourceCPU; case "memory": box.resourceMemory; default: box.resourceDisk }
    }
    private func choosePool() {
        let pools = workspace.resources.pools
        if pools.contains(where: { $0.id == poolID }) { return }
        poolID = [initialPoolID, workspace.resources.defaultPoolID, pools.first?.id].compactMap { $0 }.first(where: { id in pools.contains { $0.id == id } }) ?? ""
    }
    private func refresh(force: Bool) {
        Task {
            let generation = workspace.connectionID
            await workspace.refreshResources(force: force)
            guard generation == workspace.connectionID else { return }
            choosePool()
        }
    }
    private func resourceSummary(_ pool: ResourcePool, now: Date) -> some View {
        let health = workspace.resources.health(pool.id, now: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                metric("CPU", value: ResourceValue.cpu(pool.totalCPU(boxes: boxes)), capacity: pool.cpuCapacity.map { ResourceValue.cpu($0) + " cores" })
                metric("Memory", value: ResourceValue.bytes(pool.totalMemory(boxes: boxes)), capacity: pool.memoryCapacity.map(ResourceValue.bytes))
                metric("Data disk", value: ResourceValue.bytes(pool.dataAvailable), capacity: "available")
            }
            ResourceHealthNotice(health: health, reportedAt: pool.reportedAt)
            HStack(spacing: 18) {
                Text("Box data: " + ResourceValue.bytes(pool.dataBytes))
                Text("Shared cache: " + ResourceValue.bytes(pool.cacheBytes))
                Text("Build storage: " + ResourceValue.bytes(pool.buildBytes))
            }.font(.caption).foregroundStyle(.secondary)
            if let observed = pool.storageObservedAt {
                Text("Storage breakdown measured \(observed, style: .relative) ago; updates less often than CPU and memory.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Storage breakdown has not been measured yet.").font(.caption).foregroundStyle(.secondary) }
            Text(PoolResourceHealth.cacheLimitation).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private func metric(_ title: String, value: String, capacity: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let capacity { Text(capacity == "available" ? capacity : "of " + capacity).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func boxDetail(_ box: Sandbox) -> some View {
        DisclosureGroup("Details · " + box.displayName) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if let observed = box.resourceObservedAt { Text("CPU and memory measured \(observed, style: .relative) ago").foregroundStyle(.secondary) }
                    Text("Memory is the cgroup charge, including page cache. Process resident totals can count shared pages more than once.").foregroundStyle(.secondary)
                    Text("Process resident memory: " + ResourceValue.bytes(box.isRunning ? box.resourceReport["memory"]["residentBytes"].number : nil))
                    Text("Sources: " + ResourceValue.bytes(box.resourceReport["storage"]["sourcesBytes"].number) + " · Workspace data: " + ResourceValue.bytes(box.resourceReport["storage"]["dataBytes"].number))
                    ForEach(Array(box.resourceReport["processes"].array.prefix(10).enumerated()), id: \.offset) { _, process in
                        HStack {
                            Text(process["command"].string).lineLimit(1)
                            Spacer()
                            Text(ResourceValue.cpu(process["vcpus"].number) + " cores · " + ResourceValue.bytes(process["residentBytes"].number)).monospacedDigit()
                        }
                    }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 110)
        }
    }
    private func stopSelected() {
        let targets = selectedRunning, generation = workspace.connectionID
        stopping = true; actionError = nil
        Task {
            var failures: [String] = []
            for box in targets {
                do {
                    try await workspace.performBoxAction(.stop, boxID: box.id, connection: generation, refreshAfter: false) {
                        terminals?.closeBox(box.id, connection: generation)
                        forwards?.close(box: box.id); desktops?.close(box: box.id)
                    }
                }
                catch { failures.append(box.displayName + ": " + error.localizedDescription) }
            }
            if generation == workspace.connectionID { await workspace.refresh() }
            actionError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            stopping = false
        }
    }
}

struct ResourceHealthNotice: View {
    let health: PoolResourceHealth
    var reportedAt: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(health.messages, id: \.self) { message in
                Label(message, systemImage: symbol).font(.callout)
                    .foregroundStyle(health.level == .blocked ? Color.red : health.level == .warning ? Color.orange : Color.secondary)
            }
            if let reportedAt { Text("Reported \(reportedAt, style: .relative) ago").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var symbol: String {
        switch health.level {
        case .blocked, .warning: "exclamationmark.triangle"
        case .stale: "clock.badge.exclamationmark"
        case .healthy: "internaldrive"
        case .unknown: "questionmark.circle"
        }
    }
}

struct PoolCacheClearRequest: Identifiable {
    let id = UUID()
    let pool: ResourcePool
    let connection: UUID
}

struct PoolCacheClearSheet: View {
    let request: PoolCacheClearRequest
    let computer: String
    @Environment(Workspace.self) private var workspace
    @Environment(TerminalStore.self) private var terminals: TerminalStore?
    @Environment(ServiceForwards.self) private var forwards: ServiceForwards?
    @Environment(DesktopWindows.self) private var desktops: DesktopWindows?
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var result: Workspace.CacheClearResult?
    @State private var failure: String?
    private var running: [Sandbox] { workspace.sandboxes.filter { $0.poolId == request.pool.id && $0.isRunning } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear pool caches?").font(.title2.bold())
            Text(computer + " › " + request.pool.name).foregroundStyle(.secondary)
            if let result {
                Label("Caches cleared. \(result.stoppedSandboxIds.count) boxes stopped.", systemImage: "checkmark.circle")
                Text("Boxes stay stopped until you start them. Resource reports may take about 30 seconds to update.")
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Every running box on this pool will stop, including boxes started by another client while this window is open.")
                if !running.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) { ForEach(running) { box in Label(box.displayName, systemImage: "stop.circle").lineLimit(2) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: min(130, CGFloat(running.count) * 30 + 8))
                }
                Text("Removes shared package and tool caches, Docker build caches, proxy downloads, and images pushed to the pool registry. Pushed images must be pushed again.")
                Text("Workspaces, source files, configuration, and secrets are kept. Boxes are not restarted automatically.").fontWeight(.medium)
                if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                if working { ProgressView("Stopping boxes and clearing caches…") }
                HStack {
                    Button(failure == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                    Spacer()
                    Button("Stop Boxes & Clear Caches", role: .destructive) { clear() }
                        .disabled(working || failure != nil || request.connection != workspace.connectionID)
                        .accessibilityIdentifier("resources.confirmClear")
                }
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(working)
    }
    private func clear() {
        working = true
        Task {
            defer { working = false }
            do {
                result = try await workspace.clearPoolCache(poolID: request.pool.id, connection: request.connection) { ids in
                    for id in ids {
                        terminals?.closeBox(id, connection: request.connection)
                        forwards?.close(box: id); desktops?.close(box: id)
                    }
                }
            } catch {
                failure = error.localizedDescription + " Cleanup may still be running. Refresh the pool before trying again; this request was not retried."
            }
        }
    }
}
