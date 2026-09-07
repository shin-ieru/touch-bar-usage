import XCTest
@testable import TouchBarUsageKit

/// Fixtures follow the app server's own generated JSON schema
/// (`codex app-server generate-json-schema`), and the standard case mirrors a
/// real observed response.
final class CodexUsageParserTests: XCTestCase {

    func testParsesFiveHourAndWeekly() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-standard"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.providerID, "codex")
        XCTAssertEqual(snapshot.windows.count, 2)

        let short = try XCTUnwrap(snapshot.shortWindow)
        XCTAssertEqual(short.usedPercent, 84)
        XCTAssertEqual(short.label, "5h")
        XCTAssertEqual(short.duration, 300 * 60)
        XCTAssertNotNil(short.resetAt)

        let weekly = try XCTUnwrap(snapshot.weeklyWindow)
        XCTAssertEqual(weekly.usedPercent, 51)
        XCTAssertEqual(weekly.longLabel, "Week")
        XCTAssertEqual(weekly.duration, 10_080 * 60)
    }

    /// `primary` is not guaranteed to be the 5-hour window; classification is by
    /// duration. Getting this wrong silently swaps the two figures.
    func testClassifiesByDurationNotByFieldName() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-reversed-order"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 84, "5h came from `secondary`")
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 51, "weekly came from `primary`")
    }

    /// Some accounts report only the weekly bucket. Nothing may be invented.
    func testWeeklyOnlyLeavesShortWindowAbsent() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-weekly-only"), fetchedAt: .testNow)
        XCTAssertNil(snapshot.shortWindow, "a missing 5h window must not be fabricated")
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 31)
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    /// The detail view has to *say* the 5h window is absent, not just omit it.
    func testWeeklyOnlyDetailReportsMissingShortWindow() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-weekly-only"), fetchedAt: .testNow)
        let detail = DetailViewModel.make(providerName: "Codex", state: .ready(snapshot), now: .testNow)

        let first = try XCTUnwrap(detail.rows.first)
        XCTAssertEqual(first.label, "5h")
        XCTAssertEqual(first.usage, "not reported")
        XCTAssertFalse(detail.rows.contains { $0.usage.contains("0% used") },
                       "must never render a fabricated zero")
    }

    func testFiveHourOnly() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-five-hour-only"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 66)
        XCTAssertNil(snapshot.weeklyWindow)
    }

    /// Older servers expose only the single-bucket view.
    func testFallsBackToLegacyRateLimits() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-legacy-only"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 12)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 22)
    }

    /// Other metered products may share the response; only `codex` is ours.
    func testPrefersCodexBucketAmongUnrelatedLimitIDs() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-unrelated-limit-ids"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 42, "must not pick sora or other")
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 17)
    }

    /// `rateLimitsByLimitId` wins over the legacy field when both are present.
    func testMultiBucketViewTakesPrecedenceOverLegacy() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-unrelated-limit-ids"), fetchedAt: .testNow)
        XCTAssertNotEqual(snapshot.shortWindow?.usedPercent, 5, "5 is the legacy value")
    }

    /// A duration we do not recognise stays representable rather than being
    /// forced into the 5h or weekly slot.
    func testUnknownDurationBecomesOtherAndIsLabelledHonestly() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-unknown-duration"), fetchedAt: .testNow)
        XCTAssertNil(snapshot.shortWindow, "1440 minutes is not the 5-hour window")
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 60)

        let other = try XCTUnwrap(snapshot.windows.first { $0.category == .other })
        XCTAssertEqual(other.usedPercent, 40)
        XCTAssertEqual(other.longLabel, "1d")
    }

    func testHumanDurationFormatting() {
        XCTAssertEqual(CodexUsageParser.humanDuration(1440), "1d")
        XCTAssertEqual(CodexUsageParser.humanDuration(180), "3h")
        XCTAssertEqual(CodexUsageParser.humanDuration(45), "45m")
        XCTAssertEqual(CodexUsageParser.humanDuration(10_080), "7d")
    }

    func testMissingResetTimestamps() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-missing-reset"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertNil(snapshot.shortWindow?.resetAt)
        XCTAssertNil(snapshot.weeklyWindow?.resetAt)
    }

    func testOutOfRangePercentagesAreClamped() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-malformed-values"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 100)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 0)
    }

    func testResponseWithNoWindowsThrows() {
        XCTAssertThrowsError(try CodexUsageParser.parse(data: Fixture.data("codex-no-windows"))) { error in
            XCTAssertEqual(error as? CodexUsageParser.ParseError, .noWindows)
        }
    }

    func testMalformedBodyThrows() {
        XCTAssertThrowsError(try CodexUsageParser.parse(data: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? CodexUsageParser.ParseError, .malformed)
        }
        XCTAssertThrowsError(try CodexUsageParser.parse(data: Data()))
    }

    func testResetTimestampsAreUnixSeconds() throws {
        let snapshot = try CodexUsageParser.parse(data: Fixture.data("codex-standard"), fetchedAt: .testNow)
        let reset = try XCTUnwrap(snapshot.shortWindow?.resetAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 1_788_756_035, accuracy: 1)
    }

    /// Percentages are "used" for every provider; a mismatch here would show
    /// remaining for one and used for the other.
    func testSemanticsMatchClaude() throws {
        let codex = try CodexUsageParser.parse(data: Fixture.data("codex-standard"), fetchedAt: .testNow)
        let claude = try ClaudeUsageParser.parse(data: Fixture.data("usage-standard"), fetchedAt: .testNow)

        let codexModel = TouchBarViewModel.make(providerName: "Codex", state: .ready(codex))
        let claudeModel = TouchBarViewModel.make(providerName: "Claude", state: .ready(claude))

        XCTAssertEqual(codexModel.segments.map(\.label), ["5h", "W"])
        XCTAssertEqual(claudeModel.segments.map(\.label), ["5h", "W"])
        XCTAssertEqual(codexModel.segments.first?.value, "84%")
        XCTAssertEqual(DetailViewModel.make(providerName: "Codex", state: .ready(codex), now: .testNow)
            .rows.first?.usage, "84% used")
    }
}
