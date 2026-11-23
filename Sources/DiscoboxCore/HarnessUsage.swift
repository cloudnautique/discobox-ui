import Foundation
import Observation

public struct QuotaWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?
}

public struct HarnessQuota: Sendable, Equatable {
    public let observedAt: Date
    public let windows: [QuotaWindow]
}

/// Strict adapters for recorded payloads; unknown schemas never become zero usage.
public enum QuotaParser {
    public static func headers(_ headers: [String: [String]]) -> [QuotaWindow] {
        let headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        return [("5h", "5-hour window"), ("7d", "Weekly")].compactMap { key, title in
            let prefix = "anthropic-ratelimit-unified-" + key
            guard let raw = headers[prefix + "-utilization"]?.first, let fraction = Double(raw),
                  fraction.isFinite, (0...1).contains(fraction) else { return nil }
            let reset = headers[prefix + "-reset"]?.first.flatMap(Double.init).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            return QuotaWindow(id: key, title: title, usedPercent: fraction * 100, resetsAt: reset)
        }
    }
    public static func date(_ text: String) -> Date? {
        ServerDate.parse(text)
    }
    public static func parse(_ text: String, provider: String) -> [QuotaWindow] {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        var windows: [QuotaWindow] = []
        if provider == "codex", let limits = root["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                guard let window = limits[key] as? [String: Any], let used = number(window["used_percent"]), (0...100).contains(used) else { continue }
                let seconds = number(window["limit_window_seconds"]).flatMap { (1...31_536_000).contains($0) ? $0 : nil }
                let title = seconds == 604800 ? "Weekly" : seconds == 18000 ? "5-hour window" : seconds.map { "\(Int($0 / 3600))-hour window" } ?? (key == "primary_window" ? "Primary window" : "Secondary window")
                windows.append(.init(id: key, title: title, usedPercent: used, resetsAt: number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }))
            }
        } else if provider == "claude" {
            for (key, title) in [("five_hour", "5-hour window"), ("seven_day", "Weekly"), ("seven_day_sonnet", "Weekly · Sonnet"), ("seven_day_opus", "Weekly · Opus")] {
                guard let window = root[key] as? [String: Any], let used = number(window["utilization"]), (0...100).contains(used) else { continue }
                windows.append(.init(id: key, title: title, usedPercent: used, resetsAt: (window["resets_at"] as? String).flatMap(date)))
            }
        }
        return windows
    }
}

import CoreFoundation

@MainActor @Observable
public final class HarnessUsage {
    public private(set) var harnesses: [Harness] = []
    public private(set) var snapshots: [String: HarnessQuota] = [:]
    public private(set) var notices: [String] = []
    public private(set) var isLoading = false
    public private(set) var lastCheckedAt: Date?
    public private(set) var refreshDelayed = false
    @ObservationIgnored private var progress = UsageProgress()
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let now: () -> Date
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func refresh(client: any DiscoboxClient, project: String, boxes: [Sandbox], configuredHarnesses: [Harness]? = nil, force: Bool = false) async {
        // The cadence survives collapsing/reopening the view. Only one poll can
        // run, even when several UI tasks ask simultaneously.
        guard !isLoading, force || lastAttempt.map({ now().timeIntervalSince($0) >= PollingCadence.focusedUsageSeconds }) ?? true else { return }
        lastAttempt = now()
        isLoading = true
        defer { isLoading = false }
        let previous = snapshots, start = progress, date = now()
        let scheduled = GuestReadDiagnostics.scheduled, context = GuestReadDiagnostics.context
        let work = Task.detached(priority: .utility) {
            try await GuestReadDiagnostics.$context.withValue(context) {
                try await GuestReadDiagnostics.$scheduled.withValue(scheduled) {
                    try await UsageCollector.collect(client: client, project: project, boxes: boxes,
                    configured: configuredHarnesses, snapshots: previous, progress: start, now: date)
                }
            }
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            work.cancel()
        }
        defer { timeout.cancel() }
        do {
            let batch = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            // Publish once, and only changed values: incremental record updates
            // used to repeatedly relayout the sidebar and its terminal neighbor.
            if harnesses != batch.harnesses { harnesses = batch.harnesses }
            if snapshots != batch.snapshots { snapshots = batch.snapshots }
            if notices != batch.notices { notices = batch.notices }
            progress = batch.progress
            refreshDelayed = batch.delayed
            if batch.checked { lastCheckedAt = now() }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            refreshDelayed = true
            let message = ["Usage unavailable: \(error.localizedDescription)"]
            if notices != message { notices = message }
        }
    }
}

private struct UsageBatch: Sendable {
    let harnesses: [Harness]
    let snapshots: [String: HarnessQuota]
    let notices: [String]
    let checked, delayed: Bool
    let progress: UsageProgress
}

private struct UsageScope: Hashable, Sendable {
    let pool, host: String
}
private struct UsageCursor: Sendable {
    var after: String?
    var seededAt: Date?
    var checkEpoch = false
    var retryAt = Date.distantPast
    var deferred = false
    var failures = 0
    var notice: String?
}
private struct UsageProgress: Sendable {
    var cursors: [UsageScope: UsageCursor] = [:]
    var nextScope = 0
    var pending: [UsageRecord] = []
    var lastRecording: [String: UsageRecord] = [:]
}

private struct UsageRecords: Decodable, Sendable {
    let records: [UsageRecord]
    let through: String
    let full: Bool
}
private struct UsageRecord: Decodable, Sendable {
    let id, poolId, sandboxId, createdAt, provider: String
    var retryAt = Date.distantPast
    private enum CodingKeys: String, CodingKey { case id, poolId, sandboxId, createdAt, provider }

    func later(than other: Self) -> Bool {
        let time = ServerDate.parse(createdAt) ?? .distantPast, previous = ServerDate.parse(other.createdAt) ?? .distantPast
        if time != previous { return time > previous }
        if poolId != other.poolId { return poolId > other.poolId }
        return id.localizedStandardCompare(other.id) == .orderedDescending
    }
}

/// The cursor advances with the pending descriptors in the same batch. A
/// cancelled refresh can safely throw both away and replay the old page.
private enum UsageCollector {
    private static func read<T: Decodable & Sendable>(_ request: BridgeRequest, client: any DiscoboxClient, as type: T.Type) async throws -> T {
        if let budget = GuestReadDiagnostics.context?.budget { return try await budget.usageRead(request, client: client, as: type) }
        return try await client.decode(request, as: type)
    }

    static func collect(client: any DiscoboxClient, project: String, boxes: [Sandbox], configured: [Harness]?,
                        snapshots initial: [String: HarnessQuota], progress initialProgress: UsageProgress,
                        now: Date) async throws -> UsageBatch {
        var snapshots = initial, progress = initialProgress
        var notices: Set<String> = []
        let harnesses: [Harness]
        if let configured { harnesses = configured }
        else { harnesses = try await client.decode(.init(.harnesses, projectID: project), as: HarnessList.self).harnessConfigs ?? [] }
        let byBox = Dictionary(boxes.compactMap { box in box.config.harnessConfigId.map { (box.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let pools = Set(boxes.filter { byBox[$0.id] != nil }.compactMap(\.poolId)).sorted()
        let scopes = pools.flatMap { pool in ["chatgpt.com", "api.anthropic.com"].map { UsageScope(pool: pool, host: $0) } }
        let active = Set(scopes)
        progress.cursors = progress.cursors.filter { active.contains($0.key) }
        if boxes.contains(where: { byBox[$0.id] != nil && $0.poolId == nil }) { notices.insert("Some boxes have no reported pool for usage.") }

        var pages = 0, checked = false
        for _ in scopes.indices {
            if pages == 4 || progress.pending.count >= 64 || Task.isCancelled { break }
            let index = progress.nextScope % scopes.count, scope = scopes[index]
            progress.nextScope = (index + 1) % scopes.count
            var cursor = progress.cursors[scope] ?? UsageCursor()
            if cursor.retryAt > now { continue }
            // The API has no epoch for a replaced pool database. Periodically
            // reseed a bounded recent window to discover reset row numbers.
            let after = cursor.checkEpoch ? nil : cursor.after
            let limit = after == nil ? 64 - progress.pending.count : 100
            let page = BridgeRequest.UsagePage(host: scope.host, after: after, limit: limit)
            pages += 1
            do {
                let result = try await read(.init(.usage, projectID: project, poolID: scope.pool, usagePage: page), client: client, as: UsageRecords.self)
                guard result.records.count <= limit, result.records.allSatisfy({ $0.poolId == scope.pool }) else {
                    throw DiscoboxError("Invalid usage page.")
                }
                checked = true
                cursor.deferred = false
                cursor.failures = 0
                if cursor.checkEpoch, let previous = cursor.after, result.through.localizedStandardCompare(previous) != .orderedAscending {
                    // The old cursor is still valid. Read forward from it even
                    // if more than a full page arrived during this probe.
                    cursor.checkEpoch = false; cursor.seededAt = now
                    progress.cursors[scope] = cursor
                    continue
                }
                if cursor.checkEpoch { notices.insert("Audit history changed on " + scope.pool + ". Refreshed recent usage.") }
                var through = result.through, lastRetained = after, limited = false
                for row in result.records where byBox[row.sandboxId] != nil {
                    if !progress.pending.contains(where: { $0.poolId == row.poolId && $0.id == row.id }) {
                        if progress.pending.count == 64 {
                            // Forward pages arrive in write order. Read the
                            // unretained suffix again on this scope's next turn.
                            through = lastRetained ?? ""; limited = true; break
                        }
                        progress.pending.append(row)
                    }
                    lastRetained = row.id
                }
                cursor.after = through.isEmpty ? nil : through
                if after == nil { cursor.seededAt = now }
                cursor.checkEpoch = after != nil && through == after && cursor.seededAt.map { now.timeIntervalSince($0) >= 86400 } == true
                if limited || (result.full && after != nil) { cursor.notice = "Catching up on usage for " + scope.pool + "." }
                else if result.full && result.records.isEmpty { cursor.notice = "No quota recording in the latest " + String(limit) + " requests to " + scope.host + "." }
                else { cursor.notice = nil }
            } catch is GuestReadBudget.Deferred {
                cursor.deferred = true
                cursor.notice = "Waiting for pool " + scope.pool + " to resume usage."
            } catch {
                cursor.failures = min(5, cursor.failures + 1)
                cursor.retryAt = now.addingTimeInterval(min(900, 60 * pow(2, Double(cursor.failures - 1))))
                cursor.notice = "Usage unavailable for " + scope.host + " on " + scope.pool + "."
            }
            progress.cursors[scope] = cursor
        }
        notices.formUnion(progress.cursors.values.compactMap(\.notice))
        if progress.cursors.count < scopes.count { notices.insert("Catching up on usage.") }
        // Decode the newest candidate first. A failed new recording leaves
        // older candidates available to supply a reading for that harness.
        progress.pending.sort { $0.later(than: $1) }
        var pending: [UsageRecord] = [], reads = 0
        for var row in progress.pending {
            guard let harness = byBox[row.sandboxId], let at = ServerDate.parse(row.createdAt),
                  progress.lastRecording[harness].map({ row.later(than: $0) }) ?? true else { continue }
            if reads == 4 || row.retryAt > now || Task.isCancelled { pending.append(row); continue }
            reads += 1
            do {
                let windows = try await recording(row, client: client, project: project)
                if windows.isEmpty { notices.insert("An observed quota recording had no usable windows.") }
                else { snapshots[harness] = .init(observedAt: at, windows: windows); progress.lastRecording[harness] = row }
            } catch {
                if let status = (error as? DiscoboxError)?.httpStatus, [404,410].contains(status) {
                    notices.insert("A quota recording is no longer available.")
                } else {
                    row.retryAt = now.addingTimeInterval(60)
                    pending.append(row)
                    notices.insert("A quota recording could not be read.")
                }
            }
        }
        progress.pending = pending
        if !pending.isEmpty { notices.insert("Catching up on usage recordings.") }
        if Task.isCancelled { notices.insert("Usage refresh timed out. Remaining work will resume later.") }
        let delayed = Task.isCancelled || progress.cursors.values.contains { $0.failures > 0 || $0.deferred }
            || pending.contains { $0.retryAt > now }
        return UsageBatch(harnesses: harnesses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                          snapshots: snapshots, notices: notices.sorted(), checked: checked, delayed: delayed, progress: progress)
    }

    private static func recording(_ row: UsageRecord, client: any DiscoboxClient, project: String) async throws -> [QuotaWindow] {
        if row.provider == "claude-headers" {
            let response = try await read(.init(.usageHeaders, projectID: project, sandboxID: row.sandboxId,
                                                         recordID: row.id, poolID: row.poolId), client: client, as: UsageHeaders.self)
            return QuotaParser.headers(response.headers)
        }
        let body = try await read(.init(.auditBody, projectID: project, sandboxID: row.sandboxId,
                                                 recordID: row.id, action: "response", poolID: row.poolId), client: client, as: UsageBody.self)
        guard body.truncated != true, body.recordingTruncatedFrom?.isEmpty != false else { return [] }
        return QuotaParser.parse(body.text, provider: row.provider)
    }
}
private struct UsageBody: Decodable, Sendable {
    let text: String
    let truncated: Bool?
    let recordingTruncatedFrom: String?
}

private struct UsageHeaders: Decodable, Sendable { let headers: [String: [String]] }
