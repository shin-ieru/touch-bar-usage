import Foundation

/// Turns Anthropic's usage JSON into normalized windows.
///
/// The endpoint is undocumented (see docs/security-model.md), so this parser
/// assumes as little as possible: it walks whatever top-level objects it finds,
/// accepts several plausible spellings for the percentage and reset fields, and
/// routes anything it does not recognise into `.other` instead of failing.
public enum ClaudeUsageParser {
    public static let providerID = "claude"

    /// Keys that have carried the used-percentage in observed payloads.
    static let utilizationKeys = ["utilization", "used_percent", "usedPercent", "percent_used", "percentage"]
    /// Keys that have carried the reset timestamp.
    static let resetKeys = ["resets_at", "resetsAt", "reset_at", "resetAt"]

    public static func parse(data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.malformed
        }
        // Some responses nest everything under a wrapper; accept either shape.
        let container = (root["usage"] as? [String: Any]) ?? root

        var windows: [UsageWindow] = []
        for key in container.keys.sorted() {
            guard let object = container[key] as? [String: Any] else { continue }
            guard let percent = number(in: object, keys: utilizationKeys) else { continue }
            windows.append(
                UsageWindow(
                    id: key,
                    label: shortLabel(for: key),
                    longLabel: longLabel(for: key),
                    usedPercent: percent,
                    resetAt: date(in: object, keys: resetKeys),
                    duration: duration(for: key),
                    category: category(for: key)
                )
            )
        }

        guard !windows.isEmpty else { throw ParseError.noWindows }
        return UsageSnapshot(providerID: providerID, windows: windows, fetchedAt: fetchedAt)
    }

    public enum ParseError: Error, Equatable {
        case malformed
        case noWindows
    }

    // MARK: - Field extraction

    static func number(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = object[key] else { continue }
            if let d = raw as? Double, d.isFinite { return d }
            if let i = raw as? Int { return Double(i) }
            // A numeric string is still a number we can use.
            if let s = raw as? String, let d = Double(s), d.isFinite { return d }
        }
        return nil
    }

    static func date(in object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let raw = object[key] else { continue }
            if raw is NSNull { return nil }
            if let s = raw as? String, let d = parseDate(s) { return d }
            // Epoch seconds or milliseconds.
            if let n = raw as? Double, n > 0 {
                return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
            }
            if let n = raw as? Int, n > 0 {
                let d = Double(n)
                return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
            }
        }
        return nil
    }

    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - Key classification

    /// Categorisation is by meaning, never by position in the JSON.
    static func category(for key: String) -> UsageWindowCategory {
        let k = key.lowercased()
        if k.contains("five_hour") || k.contains("fivehour") || k == "five_hour" || k.contains("5h") {
            return .short
        }
        if k.contains("seven_day") || k.contains("sevenday") || k.contains("week") {
            // A seven-day bucket carrying a model family name is a per-model cap.
            return isModelScoped(k) ? .modelSpecific : .weekly
        }
        return .other
    }

    static func isModelScoped(_ loweredKey: String) -> Bool {
        let families = ["opus", "sonnet", "haiku"]
        return families.contains { loweredKey.contains($0) }
    }

    static func shortLabel(for key: String) -> String {
        switch category(for: key) {
        case .short:         return "5h"
        case .weekly:        return "W"
        case .modelSpecific: return modelName(for: key).map { String($0.prefix(1)).uppercased() } ?? "M"
        case .other:         return prettify(key)
        }
    }

    static func longLabel(for key: String) -> String {
        switch category(for: key) {
        case .short:         return "5h"
        case .weekly:        return "Week"
        case .modelSpecific: return modelName(for: key).map { "Week (\($0.capitalized))" } ?? "Week (model)"
        case .other:         return prettify(key)
        }
    }

    static func modelName(for key: String) -> String? {
        let k = key.lowercased()
        return ["opus", "sonnet", "haiku"].first { k.contains($0) }
    }

    static func duration(for key: String) -> TimeInterval? {
        switch category(for: key) {
        case .short:                    return 5 * 3600
        case .weekly, .modelSpecific:   return 7 * 24 * 3600
        case .other:                    return nil
        }
    }

    static func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
