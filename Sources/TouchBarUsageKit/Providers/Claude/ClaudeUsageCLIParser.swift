import Foundation

/// Parses the output of Claude Code's interactive `/usage` command.
///
/// This reads a **terminal UI**, which is not a stable interface. The parser is
/// therefore built around meaning rather than layout: it strips ANSI, works from
/// section labels and percentages, and never assumes a column, a width, a bar
/// glyph, or a box-drawing style. It also accepts both "% used" and "% left",
/// converting the latter, because the app's semantics are consumed quota
/// everywhere.
///
/// If Claude Code ever exposes usage non-interactively — as it already does for
/// `auth status` — this whole file should be replaced by that.
public enum ClaudeUsageCLIParser {

    public enum ParseError: Error, Equatable {
        case loginRequired
        case noUsageFound
    }

    /// Text that means "you are not signed in" rather than "parsing failed".
    static let loginMarkers = [
        "please run /login", "run /login", "not logged in", "login required",
        "you are not authenticated", "session expired. please log in",
    ]

    /// Section labels, most specific first — a per-model weekly line also
    /// contains the word "week", so it must be tested before the general one.
    private struct SectionRule {
        let markers: [String]
        let category: UsageWindowCategory
        let id: String
        let label: String
        let longLabel: String
    }

    private static let sectionRules: [SectionRule] = [
        .init(markers: ["current week (opus", "weekly (opus", "week (opus"],
              category: .modelSpecific, id: "seven_day_opus",
              label: "O", longLabel: "Week (Opus)"),
        .init(markers: ["current week (sonnet", "weekly (sonnet", "week (sonnet"],
              category: .modelSpecific, id: "seven_day_sonnet",
              label: "S", longLabel: "Week (Sonnet)"),
        .init(markers: ["current session", "session limit", "5-hour", "5 hour"],
              category: .short, id: "five_hour",
              label: "5h", longLabel: "5h"),
        .init(markers: ["current week", "weekly limit", "this week", "7-day", "7 day"],
              category: .weekly, id: "seven_day",
              label: "W", longLabel: "Week"),
    ]

    public static func parse(output: String, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let lines = logicalLines(from: output)
        let joined = lines.joined(separator: "\n").lowercased()

        // A login screen is a definite answer, not a parse failure.
        let collapsedAll = collapsed(joined)
        if loginMarkers.contains(where: { collapsedAll.contains(collapsed($0)) }) {
            throw ParseError.loginRequired
        }

        var windows: [UsageWindow] = []
        var current: SectionRule?

        for (index, line) in lines.enumerated() {
            if let rule = section(for: line) {
                current = rule
            }
            guard let rule = current else { continue }
            guard let percent = usedPercent(in: line) else { continue }

            // Reset text usually sits on the label line, the percentage line, or
            // the line just after it.
            let context = [
                line,
                index + 1 < lines.count ? lines[index + 1] : "",
                index > 0 ? lines[index - 1] : "",
            ]
            windows.removeAll { $0.id == rule.id }
            windows.append(UsageWindow(
                id: rule.id,
                label: rule.label,
                longLabel: rule.longLabel,
                usedPercent: percent,
                resetAt: nil,                     // the CLI prints prose, not a timestamp
                duration: rule.category == .short ? 5 * 3600 : 7 * 86_400,
                category: rule.category,
                resetDescription: resetText(in: context)))
            current = nil
        }

        guard !windows.isEmpty else { throw ParseError.noUsageFound }
        return UsageSnapshot(providerID: ClaudeUsageParser.providerID,
                             windows: windows.sorted { rank($0.category) < rank($1.category) },
                             fetchedAt: fetchedAt)
    }

    private static func rank(_ category: UsageWindowCategory) -> Int {
        switch category {
        case .short: return 0
        case .weekly: return 1
        case .modelSpecific: return 2
        case .other: return 3
        }
    }

    // MARK: - Normalisation

    /// Strips ANSI/control sequences and box drawing, then splits into trimmed
    /// non-empty lines. Carriage returns are treated as line breaks so terminal
    /// redraws do not glue unrelated content together.
    public static func logicalLines(from output: String) -> [String] {
        var text = output

        // CSI sequences, OSC sequences, and single-character escapes.
        //
        // These patterns are deliberately **not** raw strings: `\u{1B}` is a Swift
        // escape, and inside a raw string it would be passed to the regex engine
        // as literal text, silently stripping nothing at all.
        let esc = "\u{1B}"
        for pattern in ["\(esc)\\[[0-9;?]*[ -/]*[@-~]",
                        "\(esc)\\][^\u{07}\u{1B}]*(\u{07}|\(esc)\\\\)",
                        "\(esc)[@-Z\\\\-_]"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Box drawing, block/bar glyphs and other decoration carry no meaning here.
        text = text.replacingOccurrences(
            of: "[\u{2500}-\u{257F}\u{2580}-\u{259F}\u{25A0}-\u{25FF}\u{2022}\u{00B7}]",
            with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        // Remaining control characters, keeping newline and tab.
        text = text.replacingOccurrences(
            of: "[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}\u{7F}]",
            with: "", options: .regularExpression)

        return text
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lowercased with **all whitespace removed**.
    ///
    /// Claude Code's TUI positions words with cursor-movement sequences rather
    /// than spaces, so once ANSI is stripped the text reads `currentsession`.
    /// Label matching therefore has to ignore whitespace entirely; value
    /// extraction still works on the spaced text.
    public static func collapsed(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\s+"#, with: "",
                                               options: .regularExpression)
    }

    private static func section(for line: String) -> SectionRule? {
        let collapsedLine = collapsed(line)
        return sectionRules.first { rule in
            rule.markers.contains { collapsedLine.contains(collapsed($0)) }
        }
    }

    /// Extracts a percentage and normalises it to **used**.
    ///
    /// Claude Code has rendered this both ways; treating "left" as "used" would
    /// invert the whole display, so the wording is checked explicitly and an
    /// unqualified percentage is assumed to be "used" only when nothing says
    /// otherwise.
    static func usedPercent(in line: String) -> Double? {
        let lowered = line.lowercased()
        guard let match = lowered.range(of: #"(\d{1,3}(?:\.\d+)?)\s*%"#, options: .regularExpression),
              let value = Double(lowered[match].replacingOccurrences(of: "%", with: "")
                                             .trimmingCharacters(in: .whitespaces))
        else { return nil }

        let after = lowered[match.upperBound...]
        let describesRemaining = after.contains("left") || after.contains("remaining")
            || lowered.contains("% left") || lowered.contains("% remaining")
        return UsageWindow.clamp(describesRemaining ? 100 - value : value)
    }

    /// Pulls human reset wording out of nearby lines — "resets 2:00pm",
    /// "resets Tue Sep 9". Kept as prose because that is what the CLI gives us.
    static func resetText(in context: [String]) -> String? {
        for line in context {
            let lowered = line.lowercased()
            guard let range = lowered.range(of: #"reset(s|ting)?\b"#, options: .regularExpression)
            else { continue }
            let text = line[range.lowerBound...]
                .trimmingCharacters(in: .whitespaces)
            if text.count > 6 { return String(text.prefix(60)) }
        }
        return nil
    }
}
