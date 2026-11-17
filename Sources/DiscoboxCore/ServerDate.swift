import Foundation

/// Discobox timestamps can include fractional seconds. Keep that wire detail
/// out of views and use Foundation's localized formats for presentation.
public enum ServerDate {
    // Value-type styles are Sendable; build them once, not per parse, since
    // inventory aging parses every box's timestamps on each refresh.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    public static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return (try? fractional.parse(value)) ?? (try? whole.parse(value))
    }
    public static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
