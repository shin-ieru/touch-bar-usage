import XCTest
@testable import TouchBarUsageKit

final class RefreshCoordinatorTests: XCTestCase {

    private func coordinator(
        provider: UsageProvider,
        cache: SnapshotCaching = InMemoryCache(),
        config: RefreshCoordinator.Configuration = .init(),
        clock: Clock = Clock()
    ) -> RefreshCoordinator {
        RefreshCoordinator(provider: provider, cache: cache, configuration: config, now: { clock.now })
    }

    /// Mock carrying the same provider ID as `makeSnapshot()`, so cache round-trips
    /// resolve. A mismatched ID silently yields a cache miss.
    private func claudeMock(
        states: [ProviderState] = [],
        fallback: ProviderState = .failed("no state queued"),
        delay: TimeInterval = 0
    ) -> MockUsageProvider {
        MockUsageProvider(id: "claude", displayName: "Claude", states: states, fallback: fallback, delay: delay)
    }

    /// Mutable test clock; `RefreshCoordinator` takes an injected `now`.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date = .testNow
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }

    func testLoadingToReady() async {
        let snapshot = makeSnapshot()
        let provider = claudeMock(states: [.ready(snapshot)])
        let sut = coordinator(provider: provider)

        let initial = await sut.state
        XCTAssertEqual(initial, .loading)

        let result = await sut.refresh(trigger: .launch)
        XCTAssertEqual(result, .ready(snapshot))
    }

    func testSuccessfulRefreshWritesCache() async {
        let snapshot = makeSnapshot()
        let cache = InMemoryCache()
        let sut = coordinator(provider: claudeMock(states: [.ready(snapshot)]), cache: cache)

        _ = await sut.refresh(trigger: .launch)
        XCTAssertEqual(cache.load(providerID: "claude"), snapshot)
    }

    /// Launch shows cached numbers immediately, but always marked stale.
    func testPrimeFromCacheYieldsStaleNotReady() async {
        let cached = makeSnapshot(short: 30, weekly: 20)
        let cache = InMemoryCache()
        cache.save(cached)
        let sut = coordinator(provider: claudeMock(states: []), cache: cache)

        await sut.primeFromCache()
        let state = await sut.state
        XCTAssertEqual(state, .stale(cached, reason: "cached"))
        XCTAssertNotNil(state.snapshot, "cached numbers are still drawable")
    }

    func testCachedThenStaleThenReady() async {
        let cached = makeSnapshot(short: 30, weekly: 20)
        let fresh = makeSnapshot(short: 55, weekly: 41)
        let cache = InMemoryCache()
        cache.save(cached)
        let sut = coordinator(provider: claudeMock(states: [.ready(fresh)]), cache: cache)

        await sut.primeFromCache()
        let primed = await sut.state
        XCTAssertEqual(primed, .stale(cached, reason: "cached"))

        let result = await sut.refresh(trigger: .launch)
        XCTAssertEqual(result, .ready(fresh))
    }

    /// A transient failure must keep the last good numbers, visibly stale.
    func testReadyThenTransientFailureBecomesStale() async {
        let snapshot = makeSnapshot()
        let provider = claudeMock(states: [.ready(snapshot), .failed("boom")])
        let clock = Clock()
        let sut = coordinator(provider: provider, clock: clock)

        _ = await sut.refresh(trigger: .launch)
        clock.advance(120)
        let result = await sut.refresh(trigger: .manual)

        XCTAssertEqual(result, .stale(snapshot, reason: "boom"))
        XCTAssertEqual(result.snapshot, snapshot)
    }

    func testNoCachedSnapshotPlusNetworkFailureIsFailed() async {
        let sut = coordinator(provider: claudeMock(states: [.failed("boom")]))
        let result = await sut.refresh(trigger: .launch)
        XCTAssertEqual(result, .failed("boom"))
        XCTAssertNil(result.snapshot)
    }

    func testNoCachedSnapshotPlusOfflineIsOffline() async {
        let sut = coordinator(provider: claudeMock(states: [.offline]))
        let result = await sut.refresh(trigger: .launch)
        XCTAssertEqual(result, .offline)
    }

    func testOfflineWithCachedSnapshotIsStale() async {
        let snapshot = makeSnapshot()
        let clock = Clock()
        let sut = coordinator(provider: claudeMock(states: [.ready(snapshot), .offline]), clock: clock)
        _ = await sut.refresh(trigger: .launch)
        clock.advance(120)
        let result = await sut.refresh(trigger: .manual)
        XCTAssertEqual(result, .stale(snapshot, reason: "offline"))
    }

    /// Authentication failure must never be softened into plausible stale numbers.
    func testAuthenticationFailureIsNotMaskedByCache() async {
        let snapshot = makeSnapshot()
        let clock = Clock()
        let sut = coordinator(provider: claudeMock(states: [.ready(snapshot), .needsAuthentication]), clock: clock)

        _ = await sut.refresh(trigger: .launch)
        clock.advance(120)
        let result = await sut.refresh(trigger: .manual)

        XCTAssertEqual(result, .needsAuthentication)
        XCTAssertNil(result.snapshot, "stale numbers would hide that the user must sign in")
    }

    func testRateLimitedSetsBackoffAndBlocksAutomaticRefresh() async {
        let clock = Clock()
        let provider = claudeMock(states: [.rateLimited(retryAfter: 300), .ready(makeSnapshot())])
        let config = RefreshCoordinator.Configuration(minimumFetchInterval: 1, initialBackoff: 120)
        let sut = coordinator(provider: provider, config: config, clock: clock)

        _ = await sut.refresh(trigger: .launch)
        clock.advance(10)

        var shouldFetch = await sut.shouldFetch(trigger: .timer)
        XCTAssertFalse(shouldFetch, "backoff blocks the timer")

        clock.advance(400)
        shouldFetch = await sut.shouldFetch(trigger: .timer)
        XCTAssertTrue(shouldFetch, "backoff expires after retry-after")
        let fetches = await provider.fetchCount
        XCTAssertEqual(fetches, 1)
    }

    func testRateLimitBackoffGrowsAndResetsOnSuccess() async {
        let clock = Clock()
        let provider = claudeMock(states: [
            .rateLimited(retryAfter: nil), .rateLimited(retryAfter: nil), .ready(makeSnapshot()),
        ])
        let config = RefreshCoordinator.Configuration(minimumFetchInterval: 1, initialBackoff: 100, maximumBackoff: 1000)
        let sut = coordinator(provider: provider, config: config, clock: clock)

        _ = await sut.refresh(trigger: .launch)          // backoff → 100s
        clock.advance(150)
        _ = await sut.refresh(trigger: .timer)           // backoff → 200s
        clock.advance(150)
        let blocked = await sut.shouldFetch(trigger: .timer)
        XCTAssertFalse(blocked, "second backoff is longer than the first")

        clock.advance(100)
        let recovered = await sut.refresh(trigger: .timer)
        XCTAssertEqual(recovered.diagnosticLabel, "ready")

        clock.advance(5)   // clear the minimum-interval floor, leaving only backoff
        let cleared = await sut.shouldFetch(trigger: .timer)
        XCTAssertTrue(cleared, "success clears backoff")
    }

    /// Manual refresh bypasses backoff but still honours the hard rate floor.
    func testManualRefreshIgnoresBackoffButRespectsMinimumInterval() async {
        let clock = Clock()
        let provider = claudeMock(states: [.rateLimited(retryAfter: 600), .ready(makeSnapshot())])
        let config = RefreshCoordinator.Configuration(minimumFetchInterval: 60, initialBackoff: 600)
        let sut = coordinator(provider: provider, config: config, clock: clock)

        _ = await sut.refresh(trigger: .launch)
        clock.advance(5)
        let tooSoon = await sut.shouldFetch(trigger: .manual)
        XCTAssertFalse(tooSoon, "rate floor still applies")

        clock.advance(60)
        let allowed = await sut.shouldFetch(trigger: .manual)
        XCTAssertTrue(allowed, "manual ignores the 600s backoff")
    }

    func testCooldownSkipsRedundantFetches() async {
        let clock = Clock()
        let provider = claudeMock(states: [.ready(makeSnapshot()), .ready(makeSnapshot(short: 80))])
        let config = RefreshCoordinator.Configuration(minimumFetchInterval: 60)
        let sut = coordinator(provider: provider, config: config, clock: clock)

        _ = await sut.refresh(trigger: .launch)
        clock.advance(5)
        _ = await sut.refresh(trigger: .timer)
        let afterCooldownSkip = await provider.fetchCount
        XCTAssertEqual(afterCooldownSkip, 1, "second fetch inside cooldown is skipped")

        clock.advance(120)
        _ = await sut.refresh(trigger: .timer)
        let afterCooldown = await provider.fetchCount
        XCTAssertEqual(afterCooldown, 2)
    }

    /// Concurrent callers must coalesce onto one in-flight request.
    func testConcurrentRefreshesCoalesce() async {
        let provider = claudeMock(states: [.ready(makeSnapshot())], fallback: .ready(makeSnapshot()), delay: 0.2)
        let sut = coordinator(provider: provider)

        async let a = sut.refresh(trigger: .launch)
        async let b = sut.refresh(trigger: .manual)
        async let c = sut.refresh(trigger: .wake)
        let results = await [a, b, c]

        let fetches = await provider.fetchCount
        let overlap = await provider.maxConcurrent
        XCTAssertEqual(fetches, 1, "three callers, one network request")
        XCTAssertEqual(overlap, 1, "requests never overlap")
        XCTAssertEqual(Set(results.map(\.diagnosticLabel)).count, 1, "all callers see the same result")
    }

    func testAgedSnapshotIsPresentedAsStale() async {
        let clock = Clock()
        let old = makeSnapshot(fetchedAt: Date.testNow.addingTimeInterval(-3600))
        let config = RefreshCoordinator.Configuration(staleThreshold: 900)
        let sut = coordinator(provider: claudeMock(states: [.ready(old)]), config: config, clock: clock)

        let result = await sut.refresh(trigger: .launch)
        XCTAssertEqual(result, .stale(old, reason: "aged"))
    }

    func testObserversReceiveCurrentStateOnRegistration() async {
        let sut = coordinator(provider: claudeMock(states: [.ready(makeSnapshot())]))
        let box = StateBox()
        await sut.addObserver { state in box.record(state) }
        XCTAssertEqual(box.states.first, .loading)

        _ = await sut.refresh(trigger: .launch)
        XCTAssertEqual(box.states.count, 2)
    }

    final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ProviderState] = []
        var states: [ProviderState] { lock.lock(); defer { lock.unlock() }; return storage }
        func record(_ s: ProviderState) { lock.lock(); storage.append(s); lock.unlock() }
    }
}
