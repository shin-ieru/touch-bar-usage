import XCTest
@testable import TouchBarUsageKit

/// Fixtures are **synthetic**, hand-written to mimic the shapes Claude Code's
/// `/usage` panel renders. No live account output is committed.
///
/// This parser reads a terminal UI, which is not a stable interface, so the tests
/// lean on tolerance: several widths, colours, box styles and redraw patterns all
/// have to yield the same numbers.
final class ClaudeUsageCLIParserTests: XCTestCase {

    private func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            throw XCTSkip("missing fixture \(name).txt")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Core shapes

    func testSessionAndWeeklyPercentUsed() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-used"),
                                                      fetchedAt: .testNow)
        XCTAssertEqual(snapshot.providerID, "claude")
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 45)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 18)
        XCTAssertEqual(snapshot.shortWindow?.label, "5h")
        XCTAssertEqual(snapshot.weeklyWindow?.longLabel, "Week")
    }

    /// "% left" must be converted. Treating it as used would invert the display,
    /// which is worse than showing nothing.
    func testPercentLeftIsConvertedToPercentUsed() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-left"),
                                                      fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 45, "55% left is 45% used")
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 18, "82% left is 18% used")
    }

    func testBoxDrawingAndModelSpecificWindow() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-boxed"),
                                                      fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 35)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 12, "general weekly, not the Opus cap")
        XCTAssertEqual(snapshot.modelSpecificWindows.count, 1)
        XCTAssertEqual(snapshot.modelSpecificWindows.first?.usedPercent, 5)
        XCTAssertEqual(snapshot.modelSpecificWindows.first?.longLabel, "Week (Opus)")
    }

    func testNarrowRendering() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-narrow"),
                                                      fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 90)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 44)
    }

    /// Cursor moves, clears and carriage returns must not glue lines together.
    func testRedrawAndControlSequences() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-redraw"),
                                                      fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 20)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 7)
    }

    func testWeeklyOnly() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-weekly-only"),
                                                      fetchedAt: .testNow)
        XCTAssertNil(snapshot.shortWindow)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 30)
    }

    func testSessionOnly() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-session-only"),
                                                      fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 25)
        XCTAssertNil(snapshot.weeklyWindow)
    }

    // MARK: - Reset wording

    func testResetTextIsCaptured() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-used"),
                                                      fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.resetDescription?.lowercased(), "resets 2:00pm")
        XCTAssertEqual(snapshot.weeklyWindow?.resetDescription?.lowercased(), "resets tue sep 9")
    }

    /// The CLI gives prose, not a timestamp, so the detail row must show it
    /// verbatim rather than claiming the reset time is unknown.
    func testDetailRowUsesProseReset() throws {
        let snapshot = try ClaudeUsageCLIParser.parse(output: text("claude-cli-usage-used"),
                                                      fetchedAt: .testNow)
        let detail = DetailViewModel.make(state: .ready(snapshot), now: .testNow)
        XCTAssertEqual(detail.rows.first?.reset.lowercased(), "resets 2:00pm")
        XCTAssertFalse(detail.rows.contains { $0.reset == "reset time unknown" })
    }

    // MARK: - Definite answers vs failures

    /// A login screen is a real answer and must be distinguishable from "the
    /// parser could not cope" — one means sign in, the other must not.
    func testLoginScreenThrowsLoginRequired() throws {
        XCTAssertThrowsError(try ClaudeUsageCLIParser.parse(output: text("claude-cli-login-required"))) {
            XCTAssertEqual($0 as? ClaudeUsageCLIParser.ParseError, .loginRequired)
        }
    }

    func testUnknownErrorThrowsNoUsageFoundNotLoginRequired() throws {
        XCTAssertThrowsError(try ClaudeUsageCLIParser.parse(output: text("claude-cli-error"))) {
            XCTAssertEqual($0 as? ClaudeUsageCLIParser.ParseError, .noUsageFound,
                           "an unexplained error must never be reported as a logout")
        }
    }

    func testMalformedOutputThrows() throws {
        XCTAssertThrowsError(try ClaudeUsageCLIParser.parse(output: text("claude-cli-malformed"))) {
            XCTAssertEqual($0 as? ClaudeUsageCLIParser.ParseError, .noUsageFound)
        }
        XCTAssertThrowsError(try ClaudeUsageCLIParser.parse(output: ""))
    }

    // MARK: - Normalisation units

    func testLogicalLinesStripAnsiAndDecoration() {
        let raw = "\u{1B}[2J\u{1B}[H\u{1B}[38;5;208m███\u{1B}[0m  42% used \r\n│ Resets 5pm │\n"
        let lines = ClaudeUsageCLIParser.logicalLines(from: raw)
        XCTAssertTrue(lines.contains { $0.contains("42% used") })
        XCTAssertFalse(lines.joined().contains("\u{1B}"))
        XCTAssertFalse(lines.joined().contains("█"))
        XCTAssertFalse(lines.joined().contains("│"))
    }

    func testPercentExtraction() {
        XCTAssertEqual(ClaudeUsageCLIParser.usedPercent(in: "42% used"), 42)
        XCTAssertEqual(ClaudeUsageCLIParser.usedPercent(in: "42 % used"), 42)
        XCTAssertEqual(ClaudeUsageCLIParser.usedPercent(in: "12.5% used"), 12.5)
        XCTAssertEqual(ClaudeUsageCLIParser.usedPercent(in: "30% left"), 70)
        XCTAssertEqual(ClaudeUsageCLIParser.usedPercent(in: "30% remaining"), 70)
        XCTAssertNil(ClaudeUsageCLIParser.usedPercent(in: "no numbers here"))
    }

    func testPercentagesAreClamped() {
        XCTAssertEqual(ClaudeUsageCLIParser.usedPercent(in: "150% used"), 100)
        XCTAssertEqual(ClaudeUsageCLIParser.usedPercent(in: "150% left"), 0)
    }

    /// Whitespace and casing vary between renderings; neither should matter.
    func testToleratesWhitespaceAndCasing() throws {
        let odd = "  CURRENT SESSION  \n\n\t 61%   used   \n   resets 9:30am\n\n  Current Week  \n 3% used\n"
        let snapshot = try ClaudeUsageCLIParser.parse(output: odd, fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 61)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 3)
    }
}

/// The auth oracle: the only input allowed to conclude the user is logged out.
final class ClaudeAuthProbeTests: XCTestCase {

    func testParsesLoggedIn() {
        let json = #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}"#
        XCTAssertEqual(ClaudeAuthProbe.parse(output: json, status: 0), .loggedIn)
    }

    func testParsesLoggedOut() {
        XCTAssertEqual(ClaudeAuthProbe.parse(output: #"{"loggedIn": false}"#, status: 0), .loggedOut)
    }

    /// Update notices and warnings often precede the JSON.
    func testIgnoresLeadingNoise() {
        let output = "A new version is available.\n{\"loggedIn\": true}\n"
        XCTAssertEqual(ClaudeAuthProbe.parse(output: output, status: 0), .loggedIn)
    }

    /// Only `loggedIn` is read. Anything identifying in the payload must not be
    /// extracted, so it cannot leak into a log or diagnostics.
    func testDoesNotSurfaceAccountDetails() {
        let json = #"{"loggedIn": true, "email": "someone@example.com", "orgId": "org_SECRET"}"#
        let state = ClaudeAuthProbe.parse(output: json, status: 0)
        XCTAssertEqual(state, .loggedIn)
        // The state carries no payload at all in the logged-in case.
        XCTAssertFalse("\(state)".contains("SECRET"))
        XCTAssertFalse("\(state)".contains("example.com"))
    }

    func testUnparseableOutputIsUnknownNotLoggedOut() {
        for output in ["", "garbage", "{}", "{\"other\": 1}"] {
            let state = ClaudeAuthProbe.parse(output: output, status: 0)
            XCTAssertFalse(state.isConfirmedLoggedOut,
                           "uncertainty must never be rendered as a logout: \(output)")
        }
    }

    func testTextFallbackRecognisesExplicitLogout() {
        XCTAssertEqual(ClaudeAuthProbe.parse(output: "You are not logged in.", status: 1), .loggedOut)
        XCTAssertEqual(ClaudeAuthProbe.parse(output: "Please run /login", status: 1), .loggedOut)
    }

    func testNonZeroExitWithoutLogoutTextIsUnknown() {
        let state = ClaudeAuthProbe.parse(output: "network unreachable", status: 1)
        XCTAssertFalse(state.isConfirmedLoggedOut)
    }

    func testTimeoutIsUnknown() async {
        let probe = ClaudeAuthProbe(resolver: StubInstallationProbe(installed: true),
                                    runner: StubCommandRunner.timingOut)
        let state = await probe.authState()
        XCTAssertFalse(state.isConfirmedLoggedOut, "a timeout is not a logout")
    }

    func testNotInstalledIsUnknown() async {
        let probe = ClaudeAuthProbe(resolver: StubInstallationProbe(installed: false),
                                    runner: StubCommandRunner(output: ""))
        let state = await probe.authState()
        XCTAssertFalse(state.isConfirmedLoggedOut)
    }

    func testUsesTheDocumentedSubcommand() {
        XCTAssertEqual(ClaudeAuthProbe.arguments, ["auth", "status", "--json"])
        XCTAssertFalse(ClaudeAuthProbe.arguments.contains("login"),
                       "the probe must never attempt to log in")
    }
}

/// Probe hygiene: isolation, no tools, no nested sessions, scoped cleanup.
final class ClaudeUsageProbeTests: XCTestCase {

    func testProbeDirectoryIsDedicatedAndOutsideUserProjects() {
        let directory = ClaudeUsageProbe.defaultProbeDirectory()
        XCTAssertTrue(directory.path.contains("ClaudeProbe"))
        XCTAssertTrue(directory.path.contains("Application Support"))
    }

    /// Tools are disabled explicitly; the probe only needs the command UI.
    func testSessionDisablesTools() {
        let arguments = ClaudePTYSession.noToolArguments
        guard let index = arguments.firstIndex(of: "--allowed-tools") else {
            return XCTFail("the probe must disable tools")
        }
        XCTAssertEqual(arguments[index + 1], "", "an empty allow-list grants nothing")
        XCTAssertFalse(arguments.contains("--permission-mode"),
                       "the probe must never widen permissions")
        XCTAssertFalse(arguments.contains("bypassPermissions"))
        XCTAssertFalse(arguments.contains("-p"), "the probe must never send a prompt")
    }

    /// The CLI fallback is opt-in while it remains unverified on hardware, so a
    /// normal refresh never pays its cost.
    func testCLIFallbackIsOptInByDefault() {
        XCTAssertFalse(ClaudeUsageProbe.isEnabled,
                       "the probe must not run unless explicitly enabled")
    }

    /// Claude Code refuses to run inside another Claude Code session, and that
    /// guard is correct. The child environment is cleaned rather than relied upon.
    func testChildEnvironmentClearsNestedSessionMarkers() {
        let env = ClaudeChildEnvironment.sanitized(["CLAUDECODE": "1",
                                                    "CLAUDE_CODE_ENTRYPOINT": "cli",
                                                    "PATH": "/usr/bin"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertEqual(env["PATH"], "/usr/bin", "unrelated variables are preserved")
    }

    /// Cleanup is scoped to the probe's own scratch files. Normal Claude Code
    /// history lives elsewhere and must never be touched.
    func testOnlyProbeArtifactsAreCleanedUp() {
        XCTAssertTrue(ClaudeUsageProbe.isProbeArtifact(".claude"))
        XCTAssertTrue(ClaudeUsageProbe.isProbeArtifact("CLAUDE.md"))
        XCTAssertFalse(ClaudeUsageProbe.isProbeArtifact("history.jsonl"))
        XCTAssertFalse(ClaudeUsageProbe.isProbeArtifact("projects"))
        XCTAssertFalse(ClaudeUsageProbe.isProbeArtifact("important-user-file.txt"))
    }

    func testLaunchFailureYieldsNoSnapshot() async throws {
        let probe = ClaudeUsageProbe(resolver: StubInstallationProbe(installed: true),
                                     session: StubClaudeCLISession(.launchFailed),
                                     probeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                                        .appendingPathComponent(UUID().uuidString),
                                     enabled: true)
        let snapshot = try await probe.fetchUsage(fetchedAt: .testNow)
        XCTAssertNil(snapshot)
    }

    func testTimeoutYieldsNoSnapshot() async throws {
        let probe = ClaudeUsageProbe(resolver: StubInstallationProbe(installed: true),
                                     session: StubClaudeCLISession(.timedOut),
                                     probeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                                        .appendingPathComponent(UUID().uuidString),
                                     enabled: true)
        let snapshot = try await probe.fetchUsage(fetchedAt: .testNow)
        XCTAssertNil(snapshot)
    }

    func testNotInstalledYieldsNoSnapshot() async throws {
        let probe = ClaudeUsageProbe(resolver: StubInstallationProbe(installed: false),
                                     session: StubClaudeCLISession(.output("Current session 10% used")),
                                     probeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                                        .appendingPathComponent(UUID().uuidString),
                                     enabled: true)
        let snapshot = try await probe.fetchUsage(fetchedAt: .testNow)
        XCTAssertNil(snapshot)
    }

    func testParsesSessionOutput() async throws {
        let output = "Current session\n███ 33% used\nResets 6pm\nCurrent week\n█ 9% used\n"
        let probe = ClaudeUsageProbe(resolver: StubInstallationProbe(installed: true),
                                     session: StubClaudeCLISession(.output(output)),
                                     probeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                                        .appendingPathComponent(UUID().uuidString),
                                     enabled: true)
        let snapshot = try await probe.fetchUsage(fetchedAt: .testNow)
        XCTAssertEqual(snapshot?.shortWindow?.usedPercent, 33)
        XCTAssertEqual(snapshot?.weeklyWindow?.usedPercent, 9)
    }

    func testLoginScreenPropagatesAsLoginRequired() async {
        let probe = ClaudeUsageProbe(resolver: StubInstallationProbe(installed: true),
                                     session: StubClaudeCLISession(.output("Please run /login")),
                                     probeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                                        .appendingPathComponent(UUID().uuidString),
                                     enabled: true)
        do {
            _ = try await probe.fetchUsage(fetchedAt: .testNow)
            XCTFail("a login screen must be reported, not swallowed")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageCLIParser.ParseError, .loginRequired)
        }
    }
}
