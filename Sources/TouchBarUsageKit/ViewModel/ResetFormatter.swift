import Foundation

/// Formats reset times for the detail view. Uses the system locale and time zone.
public struct ResetFormatter: Sendable {
    private let calendar: Calendar
    private let locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    /// "resets in 2h 13m", or "resetting now" once the deadline passes.
    public func relative(to resetAt: Date, now: Date = Date()) -> String {
        let remaining = resetAt.timeIntervalSince(now)
        guard remaining > 0 else { return "resetting now" }
        return "resets in \(Self.compactDuration(remaining))"
    }

    /// Compact duration: "2h 13m", "45m", "3d 4h".
    public static func compactDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60

        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// Absolute local time: "4:00 PM" today, "Tue 4:00 PM" within the week,
    /// "12 Mar 4:00 PM" beyond that.
    public func absolute(_ resetAt: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        if calendar.isDate(resetAt, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else if let week = calendar.date(byAdding: .day, value: 7, to: now), resetAt < week {
            formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM jmm")
        }
        return formatter.string(from: resetAt)
    }

    /// "1m ago", "just now" — for the "Updated …" line.
    public static func age(since date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 45 { return "just now" }
        return "\(compactDuration(elapsed)) ago"
    }
}
