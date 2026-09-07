import XCTest
@testable import TouchBarUsageKit

final class ClaudeUsageParserTests: XCTestCase {

    func testParsesFiveHourAndSevenDay() throws {
        let snapshot = try ClaudeUsageParser.parse(data: Fixture.data("usage-standard"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.providerID, "claude")
        XCTAssertEqual(snapshot.windows.count, 2)

        let short = try XCTUnwrap(snapshot.shortWindow)
        XCTAssertEqual(short.id, "five_hour")
        XCTAssertEqual(short.label, "5h")
        XCTAssertEqual(short.usedPercent, 72.4, accuracy: 0.001)
        XCTAssertEqual(short.duration, 5 * 3600)
        XCTAssertNotNil(short.resetAt)

        let weekly = try XCTUnwrap(snapshot.weeklyWindow)
        XCTAssertEqual(weekly.label, "W")
        XCTAssertEqual(weekly.longLabel, "Week")
        XCTAssertEqual(weekly.usedPercent, 43)
    }

    /// The compact bar must pick windows by category, never by key order.
    func testSelectionIsIndependentOfKeyOrder() throws {
        let reordered = #"{"seven_day":{"utilization":43},"five_hour":{"utilization":72}}"#
        let snapshot = try ClaudeUsageParser.parse(data: Data(reordered.utf8), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 72)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 43)
    }

    func testModelSpecificWindowIsSeparateFromGeneralWeekly() throws {
        let snapshot = try ClaudeUsageParser.parse(data: Fixture.data("usage-with-model-window"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 55, "general weekly must not be the Opus cap")
        XCTAssertEqual(snapshot.modelSpecificWindows.count, 1)
        let opus = try XCTUnwrap(snapshot.modelSpecificWindows.first)
        XCTAssertEqual(opus.category, .modelSpecific)
        XCTAssertEqual(opus.longLabel, "Week (Opus)")
        XCTAssertEqual(opus.usedPercent, 88)
    }

    func testMissingWeeklyWindow() throws {
        let snapshot = try ClaudeUsageParser.parse(data: Fixture.data("usage-missing-weekly"), fetchedAt: .testNow)
        XCTAssertNotNil(snapshot.shortWindow)
        XCTAssertNil(snapshot.weeklyWindow)
    }

    func testNullAndAbsentResetTimestamps() throws {
        let snapshot = try ClaudeUsageParser.parse(data: Fixture.data("usage-null-reset"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertNil(snapshot.shortWindow?.resetAt)
        XCTAssertNil(snapshot.weeklyWindow?.resetAt)
    }

    func testPercentagesAreClamped() throws {
        let snapshot = try ClaudeUsageParser.parse(data: Fixture.data("usage-out-of-range"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 100, "over 100 clamps down")
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 0, "below 0 clamps up")
    }

    /// Non-finite values are nonsense from a broken payload; the documented
    /// contract is to treat them as 0 rather than let NaN reach layout maths.
    func testNonFinitePercentageBecomesZero() {
        XCTAssertEqual(UsageWindow.clamp(.nan), 0)
        XCTAssertEqual(UsageWindow.clamp(.infinity), 0)
        XCTAssertEqual(UsageWindow.clamp(-.infinity), 0)
        XCTAssertEqual(UsageWindow.clamp(120), 100)
        XCTAssertEqual(UsageWindow.clamp(-5), 0)
    }

    /// Anthropic adding a bucket must not break the app.
    func testUnknownFieldsAndBucketsAreTolerated() throws {
        let snapshot = try ClaudeUsageParser.parse(data: Fixture.data("usage-unknown-fields"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 30)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 40)
        let other = snapshot.windows.filter { $0.category == .other }
        XCTAssertEqual(other.count, 1, "unrecognised bucket is kept, not dropped")
        XCTAssertEqual(other.first?.id, "thirty_day_future")
        // Non-object scalars at top level are ignored rather than fatal.
        XCTAssertFalse(snapshot.windows.contains { $0.id == "account_tier" })
    }

    func testAlternativeFieldSpellingsAndEpochTimestamps() throws {
        let snapshot = try ClaudeUsageParser.parse(data: Fixture.data("usage-alt-shapes"), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 66, "numeric string accepted")
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 21)
        XCTAssertNotNil(snapshot.shortWindow?.resetAt, "epoch milliseconds accepted")
        XCTAssertNotNil(snapshot.weeklyWindow?.resetAt, "epoch seconds accepted")
    }

    func testMalformedResponseThrows() throws {
        XCTAssertThrowsError(try ClaudeUsageParser.parse(data: Fixture.data("usage-malformed"))) { error in
            XCTAssertEqual(error as? ClaudeUsageParser.ParseError, .malformed)
        }
    }

    func testResponseWithNoUsableWindowsThrows() throws {
        XCTAssertThrowsError(try ClaudeUsageParser.parse(data: Fixture.data("usage-no-windows"))) { error in
            XCTAssertEqual(error as? ClaudeUsageParser.ParseError, .noWindows)
        }
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try ClaudeUsageParser.parse(data: Data()))
    }

    func testSeverityBands() {
        XCTAssertEqual(UsageSeverity(usedPercent: 0), .normal)
        XCTAssertEqual(UsageSeverity(usedPercent: 59.9), .normal)
        XCTAssertEqual(UsageSeverity(usedPercent: 60), .elevated)
        XCTAssertEqual(UsageSeverity(usedPercent: 84.9), .elevated)
        XCTAssertEqual(UsageSeverity(usedPercent: 85), .warning)
        XCTAssertEqual(UsageSeverity(usedPercent: 94.9), .warning)
        XCTAssertEqual(UsageSeverity(usedPercent: 95), .critical)
        XCTAssertEqual(UsageSeverity(usedPercent: 100), .critical)
    }

    /// Severity must never be conveyed by colour alone.
    func testSevereStatesCarryAGlyph() {
        XCTAssertNil(UsageSeverity.normal.glyph)
        XCTAssertNil(UsageSeverity.elevated.glyph)
        XCTAssertNotNil(UsageSeverity.warning.glyph)
        XCTAssertNotNil(UsageSeverity.critical.glyph)
    }
}
