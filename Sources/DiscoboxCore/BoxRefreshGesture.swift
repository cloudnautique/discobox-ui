import Foundation

/// Recognizes a deliberate downward pull, without competing with horizontal
/// row actions. Once a gesture is horizontal, it stays excluded until release.
public struct BoxRefreshGesture {
    private var horizontal = 0.0
    private var vertical = 0.0
    private var distance = 0.0
    private var excluded = false
    private var fired = false

    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func update(x: Double, y: Double, atTop: Bool) -> Bool {
        guard !excluded, !fired else { return false }
        horizontal += abs(x)
        vertical += abs(y)
        if horizontal >= 6 && horizontal >= vertical {
            excluded = true
            return false
        }
        guard atTop, y > 0 else { distance = 0; return false }
        distance += y
        guard vertical >= horizontal * 2, distance >= 90 else { return false }
        fired = true
        return true
    }
}
