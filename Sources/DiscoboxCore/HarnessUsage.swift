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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
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
    @ObservationIgnored private var checked: Set<String> = []
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let now: () -> Date
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func refresh(client: any DiscoboxClient, project: String, boxes: [Sandbox], configuredHarnesses: [Harness]? = nil) async {
        // The cadence survives collapsing/reopening the view. Only one poll can
        // run, even when several UI tasks ask simultaneously.
        guard !isLoading, lastAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastAttempt = now()
        isLoading = true
        defer { isLoading = false }
        let previous = snapshots, visited = checked
        let work = Task.detached(priority: .utility) {
            try await withThrowingTaskGroup(of: UsageBatch.self) { group in
                group.addTask {
                    try await UsageCollector.collect(client: client, project: project, boxes: boxes,
                        configured: configuredHarnesses, snapshots: previous, checked: visited)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw DiscoboxError("Usage refresh timed out; keeping previous readings.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
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
            checked = batch.checked
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            let message = ["Usage unavailable: \(error.localizedDescription)"]
            if notices != message { notices = message }
        }
    }
}

private struct UsageBatch: Sendable {
    let harnesses: [Harness]
    let snapshots: [String: HarnessQuota]
    let notices: [String]
    let checked: Set<String>
}

/// All audit decoding, sorting and quota parsing runs outside the UI actor.
private enum UsageCollector {
    static func collect(client: any DiscoboxClient, project: String, boxes: [Sandbox], configured: [Harness]?, snapshots initial: [String: HarnessQuota], checked initialChecked: Set<String>) async throws -> UsageBatch {
        var snapshots = initial, checked = initialChecked
        var notices: [String] = []
        let harnesses: [Harness]
        if let configured { harnesses = configured }
        else { harnesses = try await client.decode(.init(.harnesses, projectID: project), as: HarnessList.self).harnessConfigs ?? [] }
        let result = try await client.decode(.init(.usage, projectID: project), as: UsageRecords.self)
        try Task.checkCancellation()
        notices = result.missing
        let byBox = Dictionary(boxes.compactMap { box in box.config.harnessConfigId.map { (box.id, $0) } }, uniquingKeysWith: { first, _ in first })
        var fetched = 0
        for row in result.records.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let harness = byBox[row.sandboxId], let at = QuotaParser.date(row.createdAt),
                  snapshots[harness].map({ $0.observedAt < at }) ?? true else { continue }
            let key = row.poolId + ":" + row.id
            guard !checked.contains(key), fetched < 8 else { continue }
            fetched += 1
            do {
                let windows: [QuotaWindow]
                if row.provider == "claude-headers" {
                    let result = try await client.decode(.init(.usageHeaders, projectID: project, sandboxID: row.sandboxId, requestID: row.id, kind: row.poolId), as: UsageHeaders.self)
                    windows = QuotaParser.headers(result.headers)
                } else {
                    let body = try await client.decode(.init(.auditBody, projectID: project, sandboxID: row.sandboxId, requestID: row.id, kind: row.poolId, action: "response"), as: UsageBody.self)
                    guard body.truncated != true, body.recordingTruncatedFrom?.isEmpty != false else {
                        notices.append("A quota recording was truncated."); continue
                    }
                    windows = QuotaParser.parse(body.text, provider: row.provider)
                }
                try Task.checkCancellation()
                if !windows.isEmpty { snapshots[harness] = .init(observedAt: at, windows: windows) }
                else { notices.append("An observed quota response had no recognized windows.") }
                checked.insert(key)
            } catch is CancellationError { throw CancellationError() }
            catch { notices.append("A quota recording could not be read.") }
        }
        if checked.count > 1000 { checked.removeAll() }
        return UsageBatch(harnesses: harnesses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, snapshots: snapshots, notices: Array(Set(notices)).sorted(), checked: checked)
    }
}
private struct UsageRecords: Decodable, Sendable {
    let records: [UsageRecord]
    let missing: [String]
}
private struct UsageRecord: Decodable, Sendable {
    let id: String
    let poolId: String
    let sandboxId: String
    let createdAt: String
    let provider: String
}
private struct UsageBody: Decodable, Sendable {
    let text: String
    let truncated: Bool?
    let recordingTruncatedFrom: String?
}

private struct UsageHeaders: Decodable, Sendable { let headers: [String: [String]] }
