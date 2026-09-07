import XCTest
@testable import TouchBarUsageKit

final class TouchBarViewModelTests: XCTestCase {

    func testCompactNormalState() {
        let vm = TouchBarViewModel.make(state: .ready(makeSnapshot(short: 72, weekly: 43)))
        XCTAssertEqual(vm.segments.map(\.combined), ["5h 72%", "W 43%"])
        XCTAssertEqual(vm.compactText, "Claude  5h 72%  W 43%")
        XCTAssertNil(vm.staleIndicator)
        XCTAssertNil(vm.statusText)
        XCTAssertTrue(vm.isInteractive)
    }

    /// The compact bar drops the provider name before it truncates a number.
    func testCondensedTextKeepsBothPercentages() {
        let vm = TouchBarViewModel.make(state: .ready(makeSnapshot(short: 72, weekly: 43)))
        XCTAssertEqual(vm.condensedText, "5h 72% W 43%")
        XCTAssertTrue(vm.condensedText.contains("72%"))
        XCTAssertTrue(vm.condensedText.contains("43%"))
    }

    func testElevatedStateHasNoGlyph() {
        let vm = TouchBarViewModel.make(state: .ready(makeSnapshot(short: 70, weekly: 10)))
        XCTAssertEqual(vm.severity, .elevated)
        XCTAssertEqual(vm.segments.first?.value, "70%")
    }

    func testWarningStateAddsGlyph() {
        let vm = TouchBarViewModel.make(state: .ready(makeSnapshot(short: 88, weekly: 10)))
        XCTAssertEqual(vm.severity, .warning)
        XCTAssertEqual(vm.segments.first?.value, "88%!")
    }

    func testCriticalStateAddsStrongerGlyph() {
        let vm = TouchBarViewModel.make(state: .ready(makeSnapshot(short: 97, weekly: 10)))
        XCTAssertEqual(vm.severity, .critical)
        XCTAssertEqual(vm.segments.first?.value, "97%!!")
    }

    /// Headline severity is the worst of the two shown windows.
    func testSeverityTakesTheWorstWindow() {
        let vm = TouchBarViewModel.make(state: .ready(makeSnapshot(short: 10, weekly: 96)))
        XCTAssertEqual(vm.severity, .critical)
    }

    func testStaleStateKeepsNumbersAndAddsNonColourIndicator() {
        let vm = TouchBarViewModel.make(state: .stale(makeSnapshot(short: 72, weekly: 43), reason: "offline"))
        XCTAssertEqual(vm.segments.count, 2, "stale still shows the last known numbers")
        XCTAssertEqual(vm.staleIndicator, TouchBarViewModel.staleGlyph)
        XCTAssertTrue(vm.compactText.hasSuffix("~"))
    }

    func testLoadingState() {
        let vm = TouchBarViewModel.make(state: .loading)
        XCTAssertEqual(vm.statusText, "loading…")
        XCTAssertTrue(vm.segments.isEmpty)
        XCTAssertFalse(vm.isInteractive)
    }

    func testAuthenticationRequiredState() {
        let vm = TouchBarViewModel.make(state: .needsAuthentication)
        XCTAssertEqual(vm.statusText, "sign in")
        XCTAssertEqual(vm.compactText, "Claude  sign in")
        XCTAssertTrue(vm.segments.isEmpty, "no stale numbers may imply things are fine")
    }

    func testRateLimitedState() {
        XCTAssertEqual(TouchBarViewModel.make(state: .rateLimited(retryAfter: 60)).statusText, "refresh later")
    }

    func testOfflineState() {
        XCTAssertEqual(TouchBarViewModel.make(state: .offline).statusText, "offline")
    }

    func testNotInstalledState() {
        XCTAssertEqual(TouchBarViewModel.make(state: .notInstalled).statusText, "not installed")
    }

    /// Failure text must not leak an internal reason string onto the Touch Bar.
    func testFailedStateShowsGenericText() {
        let vm = TouchBarViewModel.make(state: .failed("keychain access denied"))
        XCTAssertEqual(vm.statusText, "unavailable")
        XCTAssertFalse(vm.compactText.contains("keychain"))
    }

    func testMissingWeeklyWindowRendersOnlyShort() {
        let vm = TouchBarViewModel.make(state: .ready(makeSnapshot(short: 61, weekly: nil)))
        XCTAssertEqual(vm.segments.map(\.combined), ["5h 61%"])
    }

    func testPercentRounding() {
        XCTAssertEqual(TouchBarViewModel.formatPercent(72.4), "72%")
        XCTAssertEqual(TouchBarViewModel.formatPercent(72.6), "73%")
        XCTAssertEqual(TouchBarViewModel.formatPercent(150), "100%")
        XCTAssertEqual(TouchBarViewModel.formatPercent(-5), "0%")
    }

    // MARK: - Detail view

    func testDetailRowsForReadyState() throws {
        let snapshot = makeSnapshot(short: 72, weekly: 43)
        let detail = DetailViewModel.make(state: .ready(snapshot), now: .testNow)

        XCTAssertEqual(detail.title, "Claude")
        XCTAssertEqual(detail.rows.count, 2)

        let short = try XCTUnwrap(detail.rows.first)
        XCTAssertEqual(short.label, "5h")
        XCTAssertEqual(short.usage, "72% used")
        XCTAssertEqual(short.reset, "resets in 2h 13m")

        // A two-day horizon reads better as a weekday than a countdown.
        XCTAssertTrue(detail.rows[1].reset.hasPrefix("resets "))
        XCTAssertFalse(detail.rows[1].reset.contains("resets in"))
        XCTAssertEqual(detail.footer, "Updated just now")
    }

    func testDetailIncludesModelSpecificWindowsAfterHeadlines() {
        let windows = [
            UsageWindow(id: "five_hour", label: "5h", usedPercent: 10, category: .short),
            UsageWindow(id: "seven_day", label: "W", longLabel: "Week", usedPercent: 20, category: .weekly),
            UsageWindow(id: "seven_day_opus", label: "O", longLabel: "Week (Opus)", usedPercent: 90, category: .modelSpecific),
        ]
        let snapshot = UsageSnapshot(providerID: "claude", windows: windows, fetchedAt: .testNow)
        let detail = DetailViewModel.make(state: .ready(snapshot), now: .testNow)

        XCTAssertEqual(detail.rows.map(\.label), ["5h", "Week", "Week (Opus)"])
        XCTAssertEqual(detail.rows.last?.severity, .warning)
    }

    func testDetailHandlesMissingResetTime() {
        let snapshot = UsageSnapshot(
            providerID: "claude",
            windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 10, resetAt: nil, category: .short)],
            fetchedAt: .testNow)
        XCTAssertEqual(DetailViewModel.make(state: .ready(snapshot), now: .testNow).rows.first?.reset,
                       "reset time unknown")
    }

    func testDetailMarksStaleInFooter() {
        let detail = DetailViewModel.make(
            state: .stale(makeSnapshot(), reason: "offline"),
            now: Date.testNow.addingTimeInterval(300))
        XCTAssertTrue(detail.footer.contains("cached"))
        XCTAssertTrue(detail.footer.contains("offline"))
        XCTAssertTrue(detail.footer.contains("5m ago"))
    }

    func testDetailForStateWithoutSnapshot() {
        let detail = DetailViewModel.make(state: .needsAuthentication, now: .testNow)
        XCTAssertTrue(detail.rows.isEmpty)
        XCTAssertEqual(detail.footer, "sign in")
    }

    // MARK: - Reset formatting

    func testCompactDurationFormatting() {
        XCTAssertEqual(ResetFormatter.compactDuration(7_980), "2h 13m")
        XCTAssertEqual(ResetFormatter.compactDuration(3_600), "1h")
        XCTAssertEqual(ResetFormatter.compactDuration(2_700), "45m")
        XCTAssertEqual(ResetFormatter.compactDuration(30), "<1m")
        XCTAssertEqual(ResetFormatter.compactDuration(273_600), "3d 4h")
        XCTAssertEqual(ResetFormatter.compactDuration(172_800), "2d")
    }

    func testRelativeResetHandlesPassedDeadline() {
        let formatter = ResetFormatter()
        XCTAssertEqual(formatter.relative(to: Date.testNow.addingTimeInterval(-10), now: .testNow), "resetting now")
        XCTAssertEqual(formatter.relative(to: Date.testNow.addingTimeInterval(7_980), now: .testNow), "resets in 2h 13m")
    }

    func testAgeFormatting() {
        XCTAssertEqual(ResetFormatter.age(since: .testNow, now: .testNow), "just now")
        XCTAssertEqual(ResetFormatter.age(since: .testNow, now: Date.testNow.addingTimeInterval(60)), "1m ago")
        XCTAssertEqual(ResetFormatter.age(since: .testNow, now: Date.testNow.addingTimeInterval(7_200)), "2h ago")
    }
}
