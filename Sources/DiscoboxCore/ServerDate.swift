import Foundation

/// Discobox timestamps can include fractional seconds. Keep that wire detail
/// out of views and use Foundation's localized formats for presentation.
public enum ServerDate {
    public static func parse(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) ??
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value))
    }
    public static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
