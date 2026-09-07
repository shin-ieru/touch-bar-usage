import XCTest
@testable import TouchBarUsageKit

/// Provider-level state mapping. No network, no keychain, no Claude Code install.
final class ClaudeUsageProviderTests: XCTestCase {

    private func provider(
        credentials: ClaudeCredentialReading = StubCredentialReader(expiresAt: Date.testNow.addingTimeInterval(3600)),
        outcome: UsageFetchOutcome = .success(Data()),
        installed: Bool = true
    ) -> ClaudeUsageProvider {
        ClaudeUsageProvider(
            credentials: credentials,
            client: StubHTTPClient(always: outcome),
            installation: StubInstallationProbe(installed: installed),
            now: { .testNow }
        )
    }

    func testSuccessfulFetchProducesReadySnapshot() async throws {
        let data = try Fixture.data("usage-standard")
        let state = await provider(outcome: .success(data)).fetchUsage()

        let snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(state.diagnosticLabel, "ready")
        XCTAssertEqual(snapshot.shortWindow?.usedPercent ?? 0, 72.4, accuracy: 0.01)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 43)
        XCTAssertEqual(snapshot.fetchedAt, .testNow)
    }

    func testUnauthorizedBecomesNeedsAuthentication() async {
        let state = await provider(outcome: .unauthorized).fetchUsage()
        XCTAssertEqual(state, .needsAuthentication)
    }

    /// An expired token is reported, never refreshed — Claude Code owns that.
    func testExpiredTokenShortCircuitsBeforeAnyNetworkCall() async {
        let expired = StubCredentialReader(expiresAt: Date.testNow.addingTimeInterval(-60))
        let state = await ClaudeUsageProvider(
            credentials: expired,
            client: StubHTTPClient { _ in
                XCTFail("no request may be made with an expired token")
                return .success(Data())
            },
            installation: StubInstallationProbe(installed: true),
            now: { .testNow }
        ).fetchUsage()
        XCTAssertEqual(state, .needsAuthentication)
    }

    func testMissingCredentialWithClaudeInstalledNeedsAuthentication() async {
        let state = await provider(credentials: StubCredentialReader(error: .notFound), installed: true).fetchUsage()
        XCTAssertEqual(state, .needsAuthentication)
    }

    /// "Claude Code isn't here" and "Claude Code is signed out" need different fixes.
    func testMissingCredentialWithClaudeAbsentIsNotInstalled() async {
        let state = await provider(credentials: StubCredentialReader(error: .notFound), installed: false).fetchUsage()
        XCTAssertEqual(state, .notInstalled)
    }

    func testKeychainAccessDeniedIsReportedAsFailureNotAuth() async {
        let state = await provider(credentials: StubCredentialReader(error: .accessDenied)).fetchUsage()
        XCTAssertEqual(state, .failed("keychain access denied"))
    }

    func testRateLimitPropagatesRetryAfter() async {
        let state = await provider(outcome: .rateLimited(retryAfter: 300)).fetchUsage()
        XCTAssertEqual(state, .rateLimited(retryAfter: 300))
    }

    func testOfflinePropagates() async {
        let state = await provider(outcome: .offline).fetchUsage()
        XCTAssertEqual(state, .offline)
    }

    func testHTTPErrorBecomesFailedWithStatusOnly() async {
        let state = await provider(outcome: .httpError(503)).fetchUsage()
        XCTAssertEqual(state, .failed("HTTP 503"))
    }

    func testUnparseableBodyBecomesFailedNotCrash() async {
        let state = await provider(outcome: .success(Data("not json".utf8))).fetchUsage()
        XCTAssertEqual(state, .failed("unexpected usage format"))
    }

    /// A provider must never throw; every path resolves to a ProviderState.
    func testAllOutcomesResolveToAState() async {
        let outcomes: [UsageFetchOutcome] = [
            .success(Data()), .unauthorized, .rateLimited(retryAfter: nil),
            .offline, .httpError(500), .transportError,
        ]
        for outcome in outcomes {
            let state = await provider(outcome: outcome).fetchUsage()
            XCTAssertFalse(state.diagnosticLabel.isEmpty)
        }
    }

    func testProviderIdentity() {
        let p = provider()
        XCTAssertEqual(p.id, "claude")
        XCTAssertEqual(p.displayName, "Claude")
    }
}
