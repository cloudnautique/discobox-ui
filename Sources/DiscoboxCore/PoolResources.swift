import Foundation
import Observation

/// Resource blobs deliberately stay open, as they do in the TUI. An older
/// agent's missing field must not turn an entire box or pool inventory into an
/// error, and an absent measurement must never become an idle/empty reading.
public struct ResourcePool: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String?
    public let ready: Bool?
    public let schedulable: Bool?
    public let health: String?
    public let cpuVcpus: Double?
    public let memoryBytes: Double?
    public let resources: JSONValue?

    public var report: JSONValue { resources ?? .null }
    public var reportedAt: Date? { ResourceValue.date(report["reportedAt"].string) }
    public var cpuCapacity: Double? { ResourceValue.positive(cpuVcpus) ?? ResourceValue.positive(report["total"]["capacityVcpus"].number) ?? ResourceValue.positive(report["cpu"]["capacityVcpus"].number) }
    public var memoryCapacity: Double? { ResourceValue.positive(memoryBytes) ?? ResourceValue.positive(report["total"]["capacityBytes"].number) ?? ResourceValue.positive(report["memory"]["capacityBytes"].number) }
    public var dataCapacity: Double? { ResourceValue.positive(report["storage"]["filesystem"]["totalBytes"].number) }
    public var dataAvailable: Double? {
        guard let capacity = dataCapacity, let available = ResourceValue.nonnegative(report["storage"]["filesystem"]["freeBytes"].number), available <= capacity else { return nil }
        return available
    }
    public var storageObservedAt: Date? { ResourceValue.date(report["storage"]["walk"]["observedAt"].string) }
    public var cacheBytes: Double? { ResourceValue.nonnegative(report["storage"]["walk"]["cacheBytes"].number) }
    public var buildBytes: Double? { ResourceValue.nonnegative(report["storage"]["walk"]["buildBytes"].number) }
    public var dataBytes: Double? { ResourceValue.nonnegative(report["storage"]["walk"]["dataBytes"].number) }
    public var memoryAvailable: Double? { ResourceValue.nonnegative(report["memory"]["availableBytes"].number) }

    public func totalCPU(boxes: [Sandbox]) -> Double? {
        if let total = ResourceValue.nonnegative(report["total"]["cpuVcpus"].number) { return total }
        return sumMeasured(boxes: boxes, service: report["cpu"]["vcpus"].number) { $0.resourceCPU }
    }
    public func totalMemory(boxes: [Sandbox]) -> Double? {
        if let total = ResourceValue.nonnegative(report["total"]["memoryBytes"].number) { return total }
        return sumMeasured(boxes: boxes, service: report["memory"]["currentBytes"].number) { $0.resourceMemory }
    }
    private func sumMeasured(boxes: [Sandbox], service: Double?, reading: (Sandbox) -> Double?) -> Double? {
        guard var total = ResourceValue.nonnegative(service) else { return nil }
        for box in boxes where box.poolId == id && box.isRunning {
            guard let value = reading(box) else { return nil }
            total += value
        }
        return total.isFinite ? total : nil
    }
}

public extension Sandbox {
    var resourceReport: JSONValue { runtime.resources ?? .null }
    var resourceCPU: Double? { isRunning ? ResourceValue.nonnegative(resourceReport["cpu"]["vcpus"].number) : nil }
    /// Charged memory includes page cache. Resident process totals can count
    /// shared pages twice; keep those as a secondary detail, like the TUI.
    var resourceMemory: Double? { isRunning ? ResourceValue.nonnegative(resourceReport["memory"]["currentBytes"].number) : nil }
    var resourceDisk: Double? { ResourceValue.nonnegative(resourceReport["storage"]["totalBytes"].number) }
    var resourceObservedAt: Date? { ResourceValue.date(resourceReport["observedAt"].string) }
}

public enum ResourceValue {
    public static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }; return value
    }
    public static func positive(_ value: Double?) -> Double? {
        guard let value = nonnegative(value), value > 0 else { return nil }; return value
    }
    public static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
    public static func bytes(_ value: Double?) -> String {
        guard let value = nonnegative(value), value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
    public static func cpu(_ value: Double?) -> String {
        guard let value = nonnegative(value) else { return "—" }
        return String(format: "%.2f", value)
    }
}

public struct PoolResourceHealth: Equatable, Sendable {
    public enum Level: Int, Sendable { case unknown, healthy, stale, warning, blocked }
    public let level: Level
    public let messages: [String]
    public var canCreate: Bool { level != .blocked }
    public static let cacheLimitation = "Cache free space is not reported. A separate cache disk can be full even when the data disk has space."

    public init(pool: ResourcePool?, now: Date, readFailed: Bool = false, invalidatedAt: Date? = nil) {
        guard let pool else { level = .unknown; messages = ["Resource status unavailable for automatic placement."]; return }
        if pool.schedulable == false {
            level = .blocked; messages = ["This pool is not accepting new boxes."]; return
        }
        guard let reported = pool.reportedAt else { level = .unknown; messages = ["This pool has not reported resource usage."]; return }
        let age = now.timeIntervalSince(reported)
        guard !readFailed, age >= -30, age <= 90, invalidatedAt.map({ reported >= $0 }) ?? true else {
            level = .stale; messages = ["Resource measurements are out of date. Available space has not been verified."]; return
        }
        if pool.dataAvailable == 0 { level = .blocked; messages = ["The reported data disk has no available space."]; return }
        var warnings: [String] = []
        if let free = pool.dataAvailable, let capacity = pool.dataCapacity, free < max(2 * 1_073_741_824, capacity * 0.1) {
            warnings.append("Data disk space is low: \(ResourceValue.bytes(free)) available.")
        }
        if let free = pool.memoryAvailable, let capacity = pool.memoryCapacity, free < max(512 * 1_048_576, capacity * 0.05) {
            warnings.append("Available memory is low: \(ResourceValue.bytes(free)).")
        }
        if let cpu = ResourceValue.nonnegative(pool.report["total"]["cpuVcpus"].number), let capacity = pool.cpuCapacity, cpu >= capacity * 0.9 {
            warnings.append("CPU usage is high. Another box may run slowly.")
        }
        if !warnings.isEmpty { level = .warning; messages = warnings }
        else if let free = pool.dataAvailable { level = .healthy; messages = ["Reported data disk: \(ResourceValue.bytes(free)) available."] }
        else { level = .unknown; messages = ["Data disk availability was not reported."] }
    }
}

public struct PoolResourceSnapshot: Decodable, Sendable {
    public let pools: [ResourcePool]
    public let defaultPoolId: String?
}

@MainActor @Observable public final class PoolResources {
    public private(set) var pools: [ResourcePool] = []
    public private(set) var defaultPoolID: String?
    public private(set) var lastRead: Date?
    public private(set) var error: String?
    public private(set) var isRefreshing = false
    @ObservationIgnored private var load: Task<Void, Error>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var invalidated: [String: Date] = [:]
    public init() {}

    public func health(_ poolID: String?, now: Date = Date()) -> PoolResourceHealth {
        let pool = pools.first { $0.id == poolID }
        return .init(pool: pool, now: now, readFailed: error != nil, invalidatedAt: poolID.flatMap { invalidated[$0] })
    }
    public func invalidate(_ poolID: String, at date: Date) { invalidated[poolID] = date }
    public func cancel() { load?.cancel() }

    /// Coalesce preflight, sidebar, and resource-view reads. This reads cached
    /// API reports, never runs du/df or requests a scan from an agent.
    public func refresh(client: any DiscoboxClient, project: String, force: Bool = false, now: Date = Date()) async throws {
        if let load { try await load.value; return }
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < 30 { return }
        lastAttempt = now; isRefreshing = true
        let task = Task {
            do {
                let snapshot = try await client.decode(.init(.poolResources, projectID: project), as: PoolResourceSnapshot.self)
                try Task.checkCancellation()
                if pools != snapshot.pools { pools = snapshot.pools }
                defaultPoolID = snapshot.defaultPoolId
                error = nil; lastRead = now
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                throw error
            }
        }
        load = task
        defer { load = nil; isRefreshing = false }
        try await task.value
    }
}
