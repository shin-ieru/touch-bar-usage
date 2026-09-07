import Foundation

/// How a window is used by the UI. Anthropic (or a future provider) may add
/// buckets we have never seen; those land in `.other` rather than being dropped
/// or crashing the parser.
public enum UsageWindowCategory: String, Codable, Sendable, CaseIterable {
    /// The rolling short window. For Claude Code today this is the 5-hour window.
    case short
    /// The general 7-day / weekly window.
    case weekly
    /// A weekly cap scoped to one model family (e.g. a per-model 7-day limit).
    case modelSpecific
    /// Recognised as a usage window, but not one the compact UI knows how to rank.
    case other
}

/// One normalized usage window. Percentages are always "used", never "remaining",
/// and are always clamped to 0...100 at construction time.
public struct UsageWindow: Codable, Equatable, Sendable {
    /// Stable key from the provider payload (e.g. "five_hour").
    public let id: String
    /// Short human label for the compact bar (e.g. "5h", "W").
    public let label: String
    /// Longer label for the detail view (e.g. "5-hour", "Week").
    public let longLabel: String
    /// Percent of quota consumed, clamped to 0...100.
    public let usedPercent: Double
    public let resetAt: Date?
    /// Nominal length of the window, when the provider states or implies one.
    public let duration: TimeInterval?
    public let category: UsageWindowCategory

    public init(
        id: String,
        label: String,
        longLabel: String? = nil,
        usedPercent: Double,
        resetAt: Date? = nil,
        duration: TimeInterval? = nil,
        category: UsageWindowCategory
    ) {
        self.id = id
        self.label = label
        self.longLabel = longLabel ?? label
        self.usedPercent = UsageWindow.clamp(usedPercent)
        self.resetAt = resetAt
        self.duration = duration
        self.category = category
    }

    /// Providers hand us whatever the server said. Non-finite values are treated
    /// as 0 rather than propagating NaN into layout math.
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    public var severity: UsageSeverity { UsageSeverity(usedPercent: usedPercent) }
}

/// Visual severity bands. Kept here (not in the view layer) so tests can assert
/// on them without AppKit.
public enum UsageSeverity: String, Codable, Sendable, CaseIterable {
    case normal     // 0–59
    case elevated   // 60–84
    case warning    // 85–94
    case critical   // 95–100

    public init(usedPercent: Double) {
        switch UsageWindow.clamp(usedPercent) {
        case ..<60:  self = .normal
        case ..<85:  self = .elevated
        case ..<95:  self = .warning
        default:     self = .critical
        }
    }

    /// Non-colour indicator, so severity is never conveyed by hue alone.
    public var glyph: String? {
        switch self {
        case .normal, .elevated: return nil
        case .warning:           return "!"
        case .critical:          return "!!"
        }
    }
}
