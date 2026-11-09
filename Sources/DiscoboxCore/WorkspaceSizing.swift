import Foundation

public enum WorkspaceSizing {
    /// Preserve the requested proportion where it leaves useful terminal space.
    /// At narrow widths divide evenly rather than squeezing one pane to its
    /// hard minimum. This also bounds ratios saved by older clients.
    public static func fraction(preferred: Double, length: Double, minimum: Double = 360, secondaryMinimum: Double? = nil) -> Double {
        guard length.isFinite, length > 0 else { return 0.5 }
        let first = max(0, minimum), second = max(0, secondaryMinimum ?? minimum)
        if first + second > length { return first / (first + second) }
        let lower = first / length, upper = 1 - second / length
        let value = preferred.isFinite ? preferred : 0.55
        return min(upper, max(lower, value))
    }
}
