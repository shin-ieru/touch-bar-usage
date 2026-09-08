import Foundation

/// Everything the Touch Bar needs to draw, derived from `ProviderState`.
/// Deliberately free of AppKit so the renderer stays dumb and the states stay
/// unit-testable.
public struct TouchBarViewModel: Equatable, Sendable {
    /// Compact segments, in display order. Each is a label + value pair so the
    /// renderer can lay them out or drop them under width pressure.
    public struct Segment: Equatable, Sendable {
        public let label: String        // "5h"
        public let value: String        // "72%"
        public let severity: UsageSeverity
        public init(label: String, value: String, severity: UsageSeverity) {
            self.label = label
            self.value = value
            self.severity = severity
        }
        public var combined: String { "\(label) \(value)" }
    }

    public let providerName: String
    /// Segments for the compact bar. Empty when there is nothing numeric to show.
    public let segments: [Segment]
    /// Shown instead of segments when there is no data (e.g. "sign in", "offline").
    public let statusText: String?
    /// Appended to the compact bar for stale data — a glyph, not a colour.
    public let staleIndicator: String?
    public let severity: UsageSeverity
    /// True when tapping should open the detail bar.
    public let isInteractive: Bool

    public static let staleGlyph = "~"

    public init(
        providerName: String,
        segments: [Segment],
        statusText: String?,
        staleIndicator: String?,
        severity: UsageSeverity,
        isInteractive: Bool
    ) {
        self.providerName = providerName
        self.segments = segments
        self.statusText = statusText
        self.staleIndicator = staleIndicator
        self.severity = severity
        self.isInteractive = isInteractive
    }

    public static func make(providerName: String = "Claude", state: ProviderState) -> TouchBarViewModel {
        switch state {
        case .loading:
            return status(providerName, "loading…", interactive: false)

        case .ready(let snapshot):
            return TouchBarViewModel(
                providerName: providerName,
                segments: segments(from: snapshot),
                statusText: nil,
                staleIndicator: nil,
                severity: snapshot.headlineSeverity,
                isInteractive: true
            )

        case .stale(let snapshot, _):
            return TouchBarViewModel(
                providerName: providerName,
                segments: segments(from: snapshot),
                statusText: nil,
                staleIndicator: staleGlyph,
                severity: snapshot.headlineSeverity,
                isInteractive: true
            )

        case .needsAuthentication:
            return status(providerName, "sign in", interactive: true)
        case .rateLimited:
            return status(providerName, "refresh later", interactive: true)
        case .offline:
            return status(providerName, "offline", interactive: true)
        case .notInstalled:
            return status(providerName, "not installed", interactive: true)
        case .unsupported:
            return status(providerName, "unavailable", interactive: true)
        case .failed:
            return status(providerName, "unavailable", interactive: true)
        }
    }

    private static func status(_ name: String, _ text: String, interactive: Bool) -> TouchBarViewModel {
        TouchBarViewModel(
            providerName: name,
            segments: [],
            statusText: text,
            staleIndicator: nil,
            severity: .normal,
            isInteractive: interactive
        )
    }

    /// Compact bar shows exactly the short window and the general weekly window.
    /// Model-specific caps stay in the detail view so v0.1 does not get cluttered.
    private static func segments(from snapshot: UsageSnapshot) -> [Segment] {
        [snapshot.shortWindow, snapshot.weeklyWindow]
            .compactMap { $0 }
            .map { window in
                Segment(
                    label: window.label,
                    value: formatPercent(window.usedPercent) + (window.severity.glyph ?? ""),
                    severity: window.severity
                )
            }
    }

    public static func formatPercent(_ value: Double) -> String {
        "\(Int(UsageWindow.clamp(value).rounded()))%"
    }

    /// Full compact string: "Claude  5h 72%  W 43%". Used at the widest layout.
    public var compactText: String {
        var parts = [providerName]
        if let statusText { parts.append(statusText) }
        parts.append(contentsOf: segments.map(\.combined))
        if let staleIndicator { parts.append(staleIndicator) }
        return parts.joined(separator: "  ")
    }

    /// Degraded string used when width is constrained: drops the provider name
    /// but never truncates a percentage into something unreadable.
    public var condensedText: String {
        var parts: [String] = []
        if let statusText { parts.append(statusText) }
        parts.append(contentsOf: segments.map(\.combined))
        if let staleIndicator { parts.append(staleIndicator) }
        return parts.isEmpty ? providerName : parts.joined(separator: " ")
    }
}

/// Rows for the expanded detail presentation.
public struct DetailViewModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let label: String        // "5h"
        public let usage: String        // "72% used"
        public let reset: String        // "resets in 2h 13m"
        public let severity: UsageSeverity
        public init(label: String, usage: String, reset: String, severity: UsageSeverity) {
            self.label = label
            self.usage = usage
            self.reset = reset
            self.severity = severity
        }
    }

    public let title: String
    public let rows: [Row]
    public let footer: String

    public init(title: String, rows: [Row], footer: String) {
        self.title = title
        self.rows = rows
        self.footer = footer
    }

    public static func make(
        providerName: String = "Claude",
        state: ProviderState,
        now: Date = Date(),
        formatter: ResetFormatter = ResetFormatter()
    ) -> DetailViewModel {
        guard let snapshot = state.snapshot else {
            return DetailViewModel(
                title: providerName,
                rows: [],
                footer: TouchBarViewModel.make(providerName: providerName, state: state).statusText ?? "unavailable"
            )
        }

        // Headline windows first, then any model-specific caps, then anything new.
        //
        // Unrecognised buckets are kept in the snapshot for forward compatibility
        // (Anthropic's live response already carries at least one), but an empty
        // one would just be noise on a narrow bar — so `.other` is shown only
        // once it is actually being consumed.
        let ordered = [snapshot.shortWindow, snapshot.weeklyWindow].compactMap { $0 }
            + snapshot.modelSpecificWindows
            + snapshot.windows.filter { $0.category == .other && $0.usedPercent > 0 }

        let rows = ordered.map { window -> Row in
            // The CLI fallback gives prose ("resets 2:00pm") rather than a
            // timestamp, so it is used verbatim when there is no date to count
            // down from.
            var reset = window.resetDescription ?? "reset time unknown"
            if let resetAt = window.resetAt {
                let relative = formatter.relative(to: resetAt, now: now)
                // Long horizons are easier to act on with a weekday than a countdown.
                if resetAt.timeIntervalSince(now) > 12 * 3600 {
                    reset = "resets \(formatter.absolute(resetAt, now: now))"
                } else {
                    reset = relative
                }
            }
            return Row(
                label: window.longLabel,
                usage: "\(TouchBarViewModel.formatPercent(window.usedPercent)) used",
                reset: reset,
                severity: window.severity
            )
        }

        // A provider that reports no short window must say so. Showing 0%, or
        // omitting the row silently, would both read as "plenty left".
        var allRows = rows
        if snapshot.shortWindow == nil {
            allRows.insert(
                Row(label: "5h", usage: "not reported", reset: "", severity: .normal),
                at: 0)
        }

        var footer = "Updated \(ResetFormatter.age(since: snapshot.fetchedAt, now: now))"
        if case .stale(_, let reason) = state {
            footer += " · cached\(reason.map { " (\($0))" } ?? "")"
        }
        return DetailViewModel(title: providerName, rows: allRows, footer: footer)
    }
}
