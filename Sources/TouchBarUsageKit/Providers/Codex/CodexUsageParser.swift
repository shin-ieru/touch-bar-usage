import Foundation

/// Turns the Codex App Server's `account/rateLimits/read` response into
/// normalized windows.
///
/// The response shape is taken from the app server's own generated JSON schema
/// (`codex app-server generate-json-schema`), not guessed:
///
/// ```
/// GetAccountRateLimitsResponse
///   rateLimits           : RateLimitSnapshot        (required, legacy single bucket)
///   rateLimitsByLimitId  : { limitId: RateLimitSnapshot }?
///
/// RateLimitSnapshot
///   limitId, planType, primary?, secondary?, credits?, ...
///
/// RateLimitWindow
///   usedPercent (required), windowDurationMins?, resetsAt?   // unix seconds
/// ```
///
/// Two rules matter and are easy to get wrong:
///
/// - **Do not assume `primary` is the 5-hour window.** Classification is by
///   `windowDurationMins`, never by field name or ordering.
/// - **Do not fabricate a missing window.** An account that reports only a weekly
///   bucket must show "not reported", never `0%`.
public enum CodexUsageParser {
    public static let providerID = "codex"

    /// The metered bucket this app cares about.
    static let codexLimitID = "codex"

    /// Window durations, in minutes, as reported by the backend.
    static let fiveHourMinutes = 300
    static let weeklyMinutes = 10_080

    public enum ParseError: Error, Equatable {
        case malformed
        case noWindows
        case loggedOut
    }

    public static func parse(data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.malformed
        }
        return try parse(object: root, fetchedAt: fetchedAt)
    }

    public static func parse(object root: [String: Any], fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let snapshot = selectSnapshot(from: root) else { throw ParseError.malformed }

        var windows: [UsageWindow] = []
        // Both fields are optional and either may hold either duration.
        for key in ["primary", "secondary"] {
            guard let raw = snapshot[key] as? [String: Any] else { continue }
            if let window = makeWindow(from: raw, fallbackID: key) {
                windows.append(window)
            }
        }

        guard !windows.isEmpty else { throw ParseError.noWindows }

        // Deterministic order regardless of which field held which duration.
        windows.sort { lhs, rhs in
            rank(lhs.category) < rank(rhs.category)
        }
        return UsageSnapshot(providerID: providerID, windows: windows, fetchedAt: fetchedAt)
    }

    /// Prefers the multi-bucket `codex` entry; falls back to the legacy
    /// single-bucket view for older servers.
    static func selectSnapshot(from root: [String: Any]) -> [String: Any]? {
        if let byID = root["rateLimitsByLimitId"] as? [String: Any] {
            if let codex = byID[codexLimitID] as? [String: Any] {
                return codex
            }
            // Some responses key the bucket by a different metered id; if exactly
            // one bucket exists, it is unambiguous.
            let buckets = byID.values.compactMap { $0 as? [String: Any] }
            if buckets.count == 1 { return buckets[0] }
            // Otherwise prefer a bucket that names itself codex.
            if let named = buckets.first(where: { ($0["limitId"] as? String) == codexLimitID }) {
                return named
            }
        }
        return root["rateLimits"] as? [String: Any]
    }

    static func makeWindow(from raw: [String: Any], fallbackID: String) -> UsageWindow? {
        guard let percent = number(raw["usedPercent"]) else { return nil }
        let minutes = number(raw["windowDurationMins"]).map { Int($0) }
        let category = category(forMinutes: minutes)

        return UsageWindow(
            id: identifier(forMinutes: minutes, fallback: fallbackID),
            label: shortLabel(for: category, minutes: minutes),
            longLabel: longLabel(for: category, minutes: minutes),
            usedPercent: percent,
            resetAt: date(raw["resetsAt"]),
            duration: minutes.map { TimeInterval($0) * 60 },
            category: category)
    }

    // MARK: - Classification

    /// By duration only. A backend that adds a new window length stays
    /// representable as `.other` rather than being dropped or mislabelled.
    static func category(forMinutes minutes: Int?) -> UsageWindowCategory {
        switch minutes {
        case .some(fiveHourMinutes): return .short
        case .some(weeklyMinutes):   return .weekly
        default:                     return .other
        }
    }

    static func identifier(forMinutes minutes: Int?, fallback: String) -> String {
        switch category(forMinutes: minutes) {
        case .short:  return "five_hour"
        case .weekly: return "seven_day"
        default:      return minutes.map { "window_\($0)m" } ?? fallback
        }
    }

    static func shortLabel(for category: UsageWindowCategory, minutes: Int?) -> String {
        switch category {
        case .short:  return "5h"
        case .weekly: return "W"
        default:      return minutes.map { humanDuration($0) } ?? "?"
        }
    }

    static func longLabel(for category: UsageWindowCategory, minutes: Int?) -> String {
        switch category {
        case .short:  return "5h"
        case .weekly: return "Week"
        default:      return minutes.map { humanDuration($0) } ?? "Other"
        }
    }

    /// Renders an unrecognised duration honestly instead of forcing it into a
    /// bucket it does not belong to.
    static func humanDuration(_ minutes: Int) -> String {
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func rank(_ category: UsageWindowCategory) -> Int {
        switch category {
        case .short:         return 0
        case .weekly:        return 1
        case .modelSpecific: return 2
        case .other:         return 3
        }
    }

    // MARK: - Field extraction

    static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double, d.isFinite { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    /// `resetsAt` is unix **seconds**; tolerate milliseconds defensively.
    static func date(_ raw: Any?) -> Date? {
        guard let value = number(raw), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }
}
