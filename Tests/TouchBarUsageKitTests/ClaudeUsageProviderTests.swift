import XCTest
@testable import TouchBarUsageKit

final class ClaudeUsageProviderTests: XCTestCase {
    private func provider(control: ClaudeUsageProbing = StubClaudeUsageProbe(snapshot: nil),
                          fallback: ClaudeUsageProbing = StubClaudeUsageProbe(snapshot: nil),
                          auth: String = #"{"loggedIn":true}"#, status: Int32 = 0,
                          installed: Bool = true, recorder: ClaudeSourceRecorder = ClaudeSourceRecorder()) -> ClaudeUsageProvider {
        let installation = StubInstallationProbe(installed: installed)
        return ClaudeUsageProvider(installation: installation,
            authProbe: ClaudeAuthProbe(resolver: installation, runner: StubCommandRunner(output: auth, status: status)),
            control: control, usageProbe: fallback, recorder: recorder, now: { .testNow })
    }
    func testStructuredSourceWins() async {
        let recorder = ClaudeSourceRecorder()
        let state = await provider(control: StubClaudeUsageProbe(snapshot: makeSnapshot()),
                                   fallback: StubClaudeUsageProbe(snapshot: makeSnapshot(short: 1)), recorder: recorder).fetchUsage()
        XCTAssertEqual(state.snapshot?.shortWindow?.usedPercent, 72)
        let source = await recorder.source
        XCTAssertEqual(source, .controlProtocol)
    }
    func testEveryControlFailureFallsBack() async {
        for error in [ClaudeControlError.unsupported, .malformed, .timedOut, .childExited, .launchFailed, .unavailable] {
            let recorder = ClaudeSourceRecorder()
            let state = await provider(control: StubClaudeUsageProbe(error: error),
                                       fallback: StubClaudeUsageProbe(snapshot: makeSnapshot()), recorder: recorder).fetchUsage()
            XCTAssertEqual(state, .ready(makeSnapshot()))
            let source = await recorder.source
            XCTAssertEqual(source, .cli)
        }
    }
    func testLoginScreenIsNotAuthAuthority() async {
        let state = await provider(fallback: StubClaudeUsageProbe(error: ClaudeUsageCLIParser.ParseError.loginRequired)).fetchUsage()
        XCTAssertNotEqual(state, .needsAuthentication)
        XCTAssertTrue(state.diagnosticLabel.contains("signed in"))
    }
    func testFailureAuthCacheMatrix() async {
        for auth in [#"{"loggedIn":true}"#, #"{"loggedIn":false}"#, "malformed"] {
            for cached in [true, false] {
                let cache = InMemoryCache()
                if cached { cache.save(makeSnapshot()) }
                let loggedOut = auth.contains("false")
                let coordinator = RefreshCoordinator(provider: provider(auth: auth, status: loggedOut ? 1 : 0), cache: cache, now: { .testNow })
                await coordinator.primeFromCache()
                let state = await coordinator.refresh()
                if loggedOut { XCTAssertEqual(state, .needsAuthentication) }
                else if cached {
                    guard case .stale(let snapshot, _) = state else { XCTFail("expected stale"); continue }
                    XCTAssertEqual(snapshot, makeSnapshot())
                } else {
                    guard case .failed = state else { XCTFail("expected unavailable"); continue }
                }
            }
        }
    }
    func testRecoveryOnNextRefresh() async {
        let source = SequenceUsageProbe([nil, makeSnapshot()])
        let p = provider(control: source)
        let first = await p.fetchUsage()
        XCTAssertNil(first.snapshot)
        let second = await p.fetchUsage()
        XCTAssertEqual(second, .ready(makeSnapshot()))
    }
    func testNotInstalled() async {
        let result = await provider(installed: false).fetchUsage()
        XCTAssertEqual(result, .notInstalled)
    }
    func testDiagnosticsHaveNoAccountMetadata() async {
        let p = provider(auth: #"{"loggedIn":true,"email":"private@example.com","orgId":"PRIVATE"}"#)
        _ = await p.fetchUsage()
        let text = await p.diagnostics().map { $0.value }.joined()
        XCTAssertTrue(text.contains("logged in"))
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("example.com"))
    }
}

actor SequenceUsageProbe: ClaudeUsageProbing {
    var snapshots: [UsageSnapshot?]
    init(_ snapshots: [UsageSnapshot?]) { self.snapshots = snapshots }
    func fetchUsage(fetchedAt: Date) async throws -> UsageSnapshot? { snapshots.removeFirst() }
}
