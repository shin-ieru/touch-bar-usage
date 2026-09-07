import XCTest
@testable import TouchBarUsageKit

/// Provider-level state mapping. No child process, no network, no Codex install.
final class CodexUsageProviderTests: XCTestCase {

    private func provider(outcome: CodexFetchOutcome,
                          installed: Bool = true) -> CodexUsageProvider {
        CodexUsageProvider(
            client: StubCodexAppServerClient(always: outcome),
            resolver: StubCodexExecutableResolver(path: installed ? "/stub/codex" : nil),
            now: { .testNow })
    }

    private func payload(_ fixture: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data(fixture)) as? [String: Any])
    }

    func testSuccessfulFetchProducesReadySnapshot() async throws {
        let state = await provider(outcome: .success(try payload("codex-standard"))).fetchUsage()
        let snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertEqual(state.diagnosticLabel, "ready")
        XCTAssertEqual(snapshot.providerID, "codex")
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 84)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 51)
    }

    /// Codex missing must not affect Claude; the provider simply reports it.
    func testNotInstalled() async {
        let state = await provider(outcome: .success([:]), installed: false).fetchUsage()
        XCTAssertEqual(state, .notInstalled)
    }

    func testLoggedOutBecomesNeedsAuthentication() async {
        let state = await provider(outcome: .loggedOut).fetchUsage()
        XCTAssertEqual(state, .needsAuthentication)
    }

    /// A wedged server is transient: the coordinator should keep the last good
    /// snapshot and mark it stale rather than blanking Codex out.
    func testTimeoutIsTreatedAsTransient() async {
        let state = await provider(outcome: .timedOut).fetchUsage()
        XCTAssertEqual(state, .offline)
    }

    func testLaunchFailureIsReported() async {
        let state = await provider(outcome: .launchFailed).fetchUsage()
        XCTAssertEqual(state, .failed("app server would not start"))
    }

    func testUnparseableBodyBecomesFailedNotCrash() async {
        let state = await provider(outcome: .success(["unexpected": "shape"])).fetchUsage()
        XCTAssertEqual(state, .failed("unexpected usage format"))
    }

    /// Reachable account, but nothing to show. Saying so beats inventing zeroes.
    func testNoWindowsReported() async throws {
        let state = await provider(outcome: .success(try payload("codex-no-windows"))).fetchUsage()
        XCTAssertEqual(state, .failed("no rate limits reported"))
        XCTAssertNil(state.snapshot)
    }

    func testWeeklyOnlyStillProducesAReadyState() async throws {
        let state = await provider(outcome: .success(try payload("codex-weekly-only"))).fetchUsage()
        let snapshot = try XCTUnwrap(state.snapshot)
        XCTAssertNil(snapshot.shortWindow)
        XCTAssertNotNil(snapshot.weeklyWindow)

        let compact = TouchBarViewModel.make(providerName: "Codex", state: state)
        XCTAssertEqual(compact.segments.map(\.combined), ["W 31%"],
                       "no fabricated 5h segment on the bar")
    }

    /// A provider must never throw; every path resolves to a ProviderState.
    func testAllOutcomesResolveToAState() async throws {
        let outcomes: [CodexFetchOutcome] = [
            .success(try payload("codex-standard")), .notInstalled, .loggedOut,
            .launchFailed, .timedOut, .failed("boom"),
        ]
        for outcome in outcomes {
            let state = await provider(outcome: outcome).fetchUsage()
            XCTAssertFalse(state.diagnosticLabel.isEmpty)
        }
    }

    func testProviderIdentity() {
        let p = provider(outcome: .notInstalled)
        XCTAssertEqual(p.id, "codex")
        XCTAssertEqual(p.displayName, "Codex")
    }

    // MARK: - Diagnostics safety

    /// Diagnostics must be safe to paste into a public issue: presence and status
    /// only, never account identifiers or raw payloads.
    func testDiagnosticsContainNoAccountMaterial() async throws {
        var object = try payload("codex-standard")
        object["accountId"] = "acct_SECRET_VALUE"
        let text = await provider(outcome: .success(object)).diagnostics()
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")

        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("acct_"))
        XCTAssertTrue(text.contains("Codex CLI: installed"))
        XCTAssertTrue(text.contains("Codex 5h window: reported"))
        XCTAssertTrue(text.contains("Codex token access: none — App Server owns auth"))
    }

    func testDiagnosticsReportMissingShortWindowHonestly() async throws {
        let text = await provider(outcome: .success(try payload("codex-weekly-only"))).diagnostics()
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("Codex 5h window: not reported"))
        XCTAssertTrue(text.contains("Codex weekly window: reported"))
    }

    func testDiagnosticsWhenSignedOut() async {
        let text = await provider(outcome: .loggedOut).diagnostics()
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("Codex auth: signed out"))
    }
}

/// Failure isolation and the dashboard/presentation state model.
final class DashboardViewModelTests: XCTestCase {

    private func entry(_ id: String, _ name: String, _ state: ProviderState) -> DashboardViewModel.Entry {
        DashboardViewModel.Entry(providerID: id, displayName: name, state: state)
    }

    private func snapshot(_ short: Double?, _ weekly: Double, id: String = "claude") -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let short {
            windows.append(UsageWindow(id: "five_hour", label: "5h", usedPercent: short, category: .short))
        }
        windows.append(UsageWindow(id: "seven_day", label: "W", longLabel: "Week",
                                   usedPercent: weekly, category: .weekly))
        return UsageSnapshot(providerID: id, windows: windows, fetchedAt: .testNow)
    }

    /// One provider failing must leave the other fully rendered.
    func testOneProviderFailingLeavesTheOtherIntact() {
        let model = DashboardViewModel(entries: [
            entry("claude", "Claude", .ready(snapshot(72, 43))),
            entry("codex", "Codex", .needsAuthentication),
        ])
        let claude = model.entry(providerID: "claude")
        let codex = model.entry(providerID: "codex")

        XCTAssertEqual(claude?.compact.segments.map(\.combined), ["5h 72%", "W 43%"])
        XCTAssertEqual(codex?.compact.statusText, "sign in")
        XCTAssertTrue(codex?.compact.segments.isEmpty ?? false)
        XCTAssertTrue(model.hasActionableProblem)
    }

    /// The tray/menu glyph tracks the worst band across providers.
    func testWorstSeverityAcrossProviders() {
        XCTAssertEqual(DashboardViewModel(entries: [
            entry("claude", "Claude", .ready(snapshot(10, 5))),
            entry("codex", "Codex", .ready(snapshot(97, 20))),
        ]).worstSeverity, .critical)

        XCTAssertEqual(DashboardViewModel(entries: [
            entry("claude", "Claude", .ready(snapshot(70, 5))),
            entry("codex", "Codex", .ready(snapshot(10, 20))),
        ]).worstSeverity, .elevated)
    }

    /// Nothing loaded is not the same as "all good".
    func testWorstSeverityIsNilWhenNothingHasNumbers() {
        XCTAssertNil(DashboardViewModel(entries: [
            entry("claude", "Claude", .loading),
            entry("codex", "Codex", .notInstalled),
        ]).worstSeverity)
    }

    func testUnknownProviderLookupReturnsNil() {
        XCTAssertNil(DashboardViewModel(entries: []).entry(providerID: "gemini"))
    }

    // MARK: - Presentation state

    /// Normal mode is the resting state — that is what keeps the native Touch Bar
    /// working, so it must be the default.
    func testNormalModeIsNotUsageMode() {
        XCTAssertFalse(TouchBarPresentation.normal.isUsageModeOpen)
        XCTAssertNil(TouchBarPresentation.normal.detailProviderID)
    }

    func testDashboardAndDetailAreUsageMode() {
        XCTAssertTrue(TouchBarPresentation.dashboard.isUsageModeOpen)
        XCTAssertTrue(TouchBarPresentation.detail(providerID: "codex").isUsageModeOpen)
        XCTAssertEqual(TouchBarPresentation.detail(providerID: "codex").detailProviderID, "codex")
        XCTAssertNil(TouchBarPresentation.dashboard.detailProviderID)
    }

    func testPresentationTransitions() {
        var presentation = TouchBarPresentation.normal
        presentation = .dashboard
        XCTAssertTrue(presentation.isUsageModeOpen)
        presentation = .detail(providerID: "claude")
        XCTAssertEqual(presentation.detailProviderID, "claude")
        presentation = .dashboard              // Back
        XCTAssertNil(presentation.detailProviderID)
        presentation = .normal                 // explicit Close, or system sleep
        XCTAssertFalse(presentation.isUsageModeOpen)
    }

    func testDetailPagesAreProviderSpecific() {
        let model = DashboardViewModel(entries: [
            entry("claude", "Claude", .ready(snapshot(72, 43))),
            entry("codex", "Codex", .ready(snapshot(84, 51, id: "codex"))),
        ])
        XCTAssertEqual(model.entry(providerID: "claude")?.detail(now: .testNow).title, "Claude")
        XCTAssertEqual(model.entry(providerID: "codex")?.detail(now: .testNow).title, "Codex")
        XCTAssertEqual(model.entry(providerID: "codex")?.detail(now: .testNow).rows.first?.usage,
                       "84% used")
    }
}
