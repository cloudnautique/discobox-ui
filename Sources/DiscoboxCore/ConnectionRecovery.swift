import Foundation

/// Connection recovery owns only read/transport probes. Mutating requests and
/// terminal input are never replayed by this policy.
public struct ConnectionRecovery: Equatable, Sendable {
    public private(set) var failures = 0
    public private(set) var nextRetryAt: Date?
    public private(set) var isAttempting = false
    public private(set) var requiresAction = false
    public init() {}
    public var isInterrupted: Bool { failures > 0 || isAttempting }
    public mutating func begin() { isAttempting = true; nextRetryAt = nil; requiresAction = false }
    public mutating func reset() { self = .init() }
    public mutating func failed(_ error: Error, now: Date, jitter: Double = Double.random(in: 0.85...1.15)) {
        failures = min(20, failures + 1); isAttempting = false
        requiresAction = !Self.canRetry(error)
        let delays: [TimeInterval] = [2, 4, 8, 16, 30]
        let delay = min(30, delays[min(failures - 1, delays.count - 1)] * min(1.15, max(0.85, jitter)))
        nextRetryAt = requiresAction ? nil : now.addingTimeInterval(delay)
    }
    public static func canRetry(_ error: Error) -> Bool {
        if let error = error as? DiscoboxError { return error.connectionRetryable }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
                .cannotLoadFromNetwork].contains(error.code)
    }
}
