import XCTest
@testable import TouchBarUsageKit

/// Claude provider state mapping. No network, no keychain, no Claude Code install.
///
/// The governing rule, and the reason v0.1.1 exists: **an OAuth failure alone
/// must never produce `needsAuthentication`.** Only Claude Code's own auth status
/// — or its `/usage` screen explicitly asking for login — may conclude that.
final class ClaudeUsageProviderTests: XCTestCase {

    private static let loggedInJSON = #"{"loggedIn": true, "subscriptionType": "pro"}"#
    private static let loggedOutJSON = #"{"loggedIn": false}"#

    private func snapshot(_ short: Double, _ weekly: Double) -> UsageSnapshot {
        UsageSnapshot(providerID: "claude", windows: [
            UsageWindow(id: "five_hour", label: "5h", usedPercent: short, category: .short),
            UsageWindow(id: "seven_day", label: "W", longLabel: "Week",
                        usedPercent: weekly, category: .weekly),
        ], fetchedAt: .testNow)
    }

    /// `authOutput` drives the `claude auth status --json` probe; `probeSnapshot`
    /// drives the `/usage` fallback.
    private func provider(
        credentials: ClaudeCredentialReading = StubCredentialReader(expiresAt: Date.testNow.addingTimeInterval(3600)),
        outcome: UsageFetchOutcome = .success(Data()),
        installed: Bool = true,
        authOutput: String = loggedInJSON,
        authStatus: Int32 = 0,
        probeSnapshot: UsageSnapshot? = nil,
        probeError: Error? = nil,
        recorder: ClaudeSourceRecorder = ClaudeSourceRecorder()
    ) -> ClaudeUsageProvider {
        let installation = StubInstallationProbe(installed: installed)
        return ClaudeUsageProvider(
            credentials: credentials,
            client: StubHTTPClient(always: outcome),
            installation: installation,
            authProbe: ClaudeAuthProbe(resolver: installation,
                                       runner: StubCommandRunner(output: authOutput, status: authStatus)),
            usageProbe: probeError.map { StubClaudeUsageProbe(error: $0) }
                ?? StubClaudeUsageProbe(snapshot: probeSnapshot),
            recorder: recorder,
            now: { .testNow })
    }

    // MARK: - 1. OAuth succeeds

    func testOAuthSuccessProducesReadySnapshot() async throws {
        let recorder = ClaudeSourceRecorder()
        let data = try Fixture.data("usage-standard")
        let state = await provider(outcome: .success(data), recorder: recorder).fetchUsage()

        let snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(state.diagnosticLabel, "ready")
        XCTAssertEqual(snapshot.shortWindow?.usedPercent ?? 0, 72.4, accuracy: 0.01)
        let source = await recorder.source
        XCTAssertEqual(source, .oauth)
    }

    // MARK: - 2–6. OAuth fails, Claude Code is signed in → CLI fallback

    /// The exact bug from v0.1.0: the stored token has passed its expiry, Claude
    /// Code has not refreshed it yet, and the account is fine.
    func testExpiredTokenDoesNotAskTheUserToSignIn() async throws {
        let expired = StubCredentialReader(expiresAt: Date.testNow.addingTimeInterval(-3600))
        let recorder = ClaudeSourceRecorder()
        let state = await provider(credentials: expired,
                                   outcome: .unauthorized,
                                   probeSnapshot: snapshot(52, 27),
                                   recorder: recorder).fetchUsage()

        XCTAssertNotEqual(state, .needsAuthentication, "an expired token is not a logout")
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 52)
        let source = await recorder.source
        XCTAssertEqual(source, .cli)
    }

    /// An expired token must still be *tried*: the server decides, not our clock.
    func testExpiredTokenIsStillSentToTheServer() async {
        let expired = StubCredentialReader(expiresAt: Date.testNow.addingTimeInterval(-3600))
        let attempted = Attempted()
        let installation = StubInstallationProbe(installed: true)

        let state = await ClaudeUsageProvider(
            credentials: expired,
            client: StubHTTPClient { _ in attempted.mark(); return .unauthorized },
            installation: installation,
            authProbe: ClaudeAuthProbe(resolver: installation,
                                       runner: StubCommandRunner(output: Self.loggedInJSON)),
            usageProbe: StubClaudeUsageProbe(snapshot: nil),
            now: { .testNow }
        ).fetchUsage()

        XCTAssertTrue(attempted.value, "the request must be attempted despite local expiry")
        XCTAssertNotEqual(state, .needsAuthentication)
    }

    func testKeychainUnavailableFallsBackToCLI() async {
        let state = await provider(credentials: StubCredentialReader(error: .accessDenied),
                                   probeSnapshot: snapshot(40, 20)).fetchUsage()
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 40)
        XCTAssertNotEqual(state, .needsAuthentication, "a keychain prompt we cannot answer is not a logout")
    }

    func testMissingCredentialFallsBackToCLIWhenSignedIn() async {
        let state = await provider(credentials: StubCredentialReader(error: .notFound),
                                   probeSnapshot: snapshot(31, 12)).fetchUsage()
        XCTAssertEqual(state.snapshot?.weeklyWindow?.usedPercent, 12)
        XCTAssertNotEqual(state, .needsAuthentication)
    }

    func testUnauthorizedFallsBackToCLI() async {
        let state = await provider(outcome: .unauthorized, probeSnapshot: snapshot(60, 30)).fetchUsage()
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 60)
        XCTAssertNotEqual(state, .needsAuthentication, "401 alone is not proof of logout")
    }

    func testForbiddenFallsBackToCLI() async {
        // The client maps 401 and 403 to the same outcome; both must fall back.
        let state = await provider(outcome: .unauthorized, probeSnapshot: snapshot(15, 8)).fetchUsage()
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 15)
    }

    func testMalformedCredentialFallsBackToCLI() async {
        let state = await provider(credentials: StubCredentialReader(error: .malformed),
                                   probeSnapshot: snapshot(22, 11)).fetchUsage()
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 22)
        XCTAssertNotEqual(state, .needsAuthentication)
    }

    func testUnexpectedOAuthPayloadFallsBackToCLI() async {
        let state = await provider(outcome: .success(Data("not json".utf8)),
                                   probeSnapshot: snapshot(77, 44)).fetchUsage()
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 77)
    }

    // MARK: - 7. Genuine logout

    func testOAuthFailurePlusConfirmedLogoutAsksToSignIn() async {
        let state = await provider(outcome: .unauthorized,
                                   authOutput: Self.loggedOutJSON,
                                   probeSnapshot: snapshot(99, 99)).fetchUsage()
        XCTAssertEqual(state, .needsAuthentication, "Claude Code itself says signed out")
        XCTAssertNil(state.snapshot, "no stale numbers may hide a real logout")
    }

    /// The `/usage` screen showing a login prompt is also a confirmed logout.
    func testCLILoginScreenAsksToSignIn() async {
        let state = await provider(outcome: .unauthorized,
                                   probeError: ClaudeUsageCLIParser.ParseError.loginRequired).fetchUsage()
        XCTAssertEqual(state, .needsAuthentication)
    }

    // MARK: - 8–10. Neither source works

    /// The coordinator turns `.failed` into stale when a snapshot exists; the
    /// provider's job is simply never to say "sign in" here.
    func testBothSourcesFailingNeverAsksToSignIn() async {
        let state = await provider(outcome: .unauthorized, probeSnapshot: nil).fetchUsage()
        XCTAssertNotEqual(state, .needsAuthentication)
        XCTAssertEqual(state.diagnosticLabel, "failed(token rejected)")
    }

    /// End-to-end: a transient double failure with a cached snapshot must show the
    /// last good numbers, marked stale — not "sign in", not a blank bar.
    func testTransientFailureWithCacheBecomesStale() async {
        let cache = InMemoryCache()
        let good = snapshot(72, 43)
        cache.save(good)

        let coordinator = RefreshCoordinator(
            provider: provider(outcome: .unauthorized, probeSnapshot: nil),
            cache: cache,
            now: { .testNow })

        // The app primes from cache on launch; that is what makes a last-good
        // snapshot available to fall back to.
        await coordinator.primeFromCache()

        let state = await coordinator.refresh(trigger: .manual)
        XCTAssertEqual(state, .stale(good, reason: "token rejected"))
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 72)
    }

    /// A confirmed logout must *not* be softened into stale numbers.
    func testConfirmedLogoutIsNotMaskedByCache() async {
        let cache = InMemoryCache()
        cache.save(snapshot(72, 43))

        let coordinator = RefreshCoordinator(
            provider: provider(outcome: .unauthorized, authOutput: Self.loggedOutJSON),
            cache: cache,
            now: { .testNow })

        await coordinator.primeFromCache()

        let state = await coordinator.refresh(trigger: .manual)
        XCTAssertEqual(state, .needsAuthentication)
        XCTAssertNil(state.snapshot)
    }

    /// An auth probe that cannot answer is not a logout either.
    func testUnknownAuthStateDoesNotAskToSignIn() async {
        let installation = StubInstallationProbe(installed: true)
        let state = await ClaudeUsageProvider(
            credentials: StubCredentialReader(error: .notFound),
            client: StubHTTPClient(always: .unauthorized),
            installation: installation,
            authProbe: ClaudeAuthProbe(resolver: installation, runner: StubCommandRunner.timingOut),
            usageProbe: StubClaudeUsageProbe(snapshot: snapshot(33, 22)),
            now: { .testNow }
        ).fetchUsage()

        XCTAssertNotEqual(state, .needsAuthentication)
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 33)
    }

    // MARK: - 11. Recovery

    func testOAuthIsUsedAgainOnceItRecovers() async throws {
        let recorder = ClaudeSourceRecorder()
        let data = try Fixture.data("usage-standard")

        _ = await provider(outcome: .unauthorized, probeSnapshot: snapshot(50, 25),
                           recorder: recorder).fetchUsage()
        var source = await recorder.source
        XCTAssertEqual(source, .cli)

        _ = await provider(outcome: .success(data), recorder: recorder).fetchUsage()
        source = await recorder.source
        XCTAssertEqual(source, .oauth, "the fast path resumes without restarting the app")
    }

    // MARK: - Other states

    func testNotInstalledWithNoCredential() async {
        let state = await provider(credentials: StubCredentialReader(error: .notFound),
                                   installed: false).fetchUsage()
        XCTAssertEqual(state, .notInstalled)
    }

    /// Offline and rate limiting are transport conditions, not auth ones — and the
    /// CLI would fail the same way, so there is nothing to fall back to.
    func testOfflinePropagatesWithoutProbing() async {
        let state = await provider(outcome: .offline).fetchUsage()
        XCTAssertEqual(state, .offline)
    }

    func testRateLimitPropagates() async {
        let state = await provider(outcome: .rateLimited(retryAfter: 300)).fetchUsage()
        XCTAssertEqual(state, .rateLimited(retryAfter: 300))
    }

    func testProviderIdentity() {
        let p = provider()
        XCTAssertEqual(p.id, "claude")
        XCTAssertEqual(p.displayName, "Claude")
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

    // MARK: - Diagnostics

    func testDiagnosticsReportTheActiveSource() async {
        let recorder = ClaudeSourceRecorder()
        _ = await provider(outcome: .unauthorized, probeSnapshot: snapshot(50, 25),
                           recorder: recorder).fetchUsage()

        let text = await provider(recorder: recorder).diagnostics()
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")

        XCTAssertTrue(text.contains("Claude usage source: CLI fallback"))
        XCTAssertTrue(text.contains("OAuth unavailable: token rejected"))
        XCTAssertTrue(text.contains("Claude refresh token: never read or used"))
    }

    /// An expired token in Diagnostics must not read as an error the user has to
    /// fix — Claude Code refreshes it on its own.
    func testDiagnosticsExplainExpiryIsClaudeCodesJob() async {
        let expired = StubCredentialReader(expiresAt: Date.testNow.addingTimeInterval(-60))
        let text = await provider(credentials: expired).diagnostics()
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("Claude Code refreshes this itself"))
    }

    func testDiagnosticsContainNoCredentialMaterial() async {
        let secret = StubCredentialReader(token: "sk-ant-oat01-SECRET",
                                          expiresAt: Date.testNow.addingTimeInterval(3600))
        let text = await provider(credentials: secret).diagnostics()
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.lowercased().contains("sk-ant"))
    }
}

/// Records whether the HTTP client was actually called.
final class Attempted: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func mark() { lock.lock(); flag = true; lock.unlock() }
}
