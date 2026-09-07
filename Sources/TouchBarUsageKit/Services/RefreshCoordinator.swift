import Foundation

/// Owns *when* a provider is fetched and how failures degrade into stale state.
///
/// Rules it enforces:
///  - never two concurrent fetches for the same provider (callers coalesce onto
///    the in-flight one);
///  - a minimum interval between fetches, so a jumpy menu or a wake storm cannot
///    hammer an undocumented endpoint;
///  - exponential backoff after rate limiting;
///  - a transient failure keeps the last good snapshot and marks it stale rather
///    than blanking the bar.
public actor RefreshCoordinator {
    public struct Configuration: Sendable {
        /// Normal cadence between automatic refreshes.
        public var refreshInterval: TimeInterval
        /// Hard floor between any two network fetches, including manual ones.
        public var minimumFetchInterval: TimeInterval
        /// A snapshot older than this is presented as stale.
        public var staleThreshold: TimeInterval
        /// First backoff step after a 429; doubles up to `maximumBackoff`.
        public var initialBackoff: TimeInterval
        public var maximumBackoff: TimeInterval

        public init(
            refreshInterval: TimeInterval = 300,
            minimumFetchInterval: TimeInterval = 60,
            staleThreshold: TimeInterval = 900,
            initialBackoff: TimeInterval = 120,
            maximumBackoff: TimeInterval = 3600
        ) {
            self.refreshInterval = refreshInterval
            self.minimumFetchInterval = minimumFetchInterval
            self.staleThreshold = staleThreshold
            self.initialBackoff = initialBackoff
            self.maximumBackoff = maximumBackoff
        }
    }

    public enum Trigger: String, Sendable {
        case launch, timer, manual, wake
    }

    private let provider: UsageProvider
    private let cache: SnapshotCaching
    private let config: Configuration
    private let now: @Sendable () -> Date
    private let log = Log(category: "refresh")

    private var inFlight: Task<ProviderState, Never>?
    private var lastFetchStarted: Date?
    private var backoffUntil: Date?
    private var currentBackoff: TimeInterval
    private var lastGoodSnapshot: UsageSnapshot?

    public private(set) var state: ProviderState = .loading
    private var observers: [@Sendable (ProviderState) -> Void] = []

    public init(
        provider: UsageProvider,
        cache: SnapshotCaching,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.cache = cache
        self.config = configuration
        self.now = now
        self.currentBackoff = configuration.initialBackoff
    }

    public func addObserver(_ observer: @escaping @Sendable (ProviderState) -> Void) {
        observers.append(observer)
        observer(state)
    }

    /// Show cached numbers immediately on launch, explicitly marked stale until
    /// the first live refresh lands.
    public func primeFromCache() {
        guard let cached = cache.load(providerID: provider.id) else { return }
        lastGoodSnapshot = cached
        publish(.stale(cached, reason: "cached"))
    }

    /// Whether a fetch would actually run right now, without starting one.
    public func shouldFetch(trigger: Trigger) -> Bool {
        let t = now()
        if let backoffUntil, t < backoffUntil, trigger != .manual { return false }
        guard let last = lastFetchStarted else { return true }
        // Manual refresh still respects the hard floor; it just ignores backoff.
        return t.timeIntervalSince(last) >= config.minimumFetchInterval
    }

    /// Coalescing entry point. Concurrent callers await the same fetch.
    @discardableResult
    public func refresh(trigger: Trigger = .manual, force: Bool = false) async -> ProviderState {
        if let inFlight {
            log.debug("refresh coalesced", ["trigger": trigger.rawValue])
            return await inFlight.value
        }
        if !force && !shouldFetch(trigger: trigger) {
            log.debug("refresh skipped", ["trigger": trigger.rawValue])
            return state
        }

        lastFetchStarted = now()
        let task = Task<ProviderState, Never> { [provider] in
            await provider.fetchUsage()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil

        let resolved = reconcile(result)
        publish(resolved)
        return resolved
    }

    /// Maps a raw provider result onto what the user should actually see,
    /// folding in the last good snapshot and updating backoff.
    private func reconcile(_ result: ProviderState) -> ProviderState {
        switch result {
        case .ready(let snapshot):
            lastGoodSnapshot = snapshot
            cache.save(snapshot)
            resetBackoff()
            log.info("usage refresh succeeded", [
                "provider": provider.id,
                "windows": "\(snapshot.windows.count)",
            ])
            if snapshot.isStale(now: now(), threshold: config.staleThreshold) {
                return .stale(snapshot, reason: "aged")
            }
            return .ready(snapshot)

        case .rateLimited(let retryAfter):
            applyBackoff(retryAfter: retryAfter)
            log.warning("usage refresh rate limited", ["provider": provider.id])
            if let last = lastGoodSnapshot { return .stale(last, reason: "rate limited") }
            return .rateLimited(retryAfter: retryAfter)

        case .offline:
            log.warning("usage refresh offline", ["provider": provider.id])
            if let last = lastGoodSnapshot { return .stale(last, reason: "offline") }
            return .offline

        case .failed(let reason):
            log.warning("usage refresh failed", ["provider": provider.id, "reason": reason])
            if let last = lastGoodSnapshot { return .stale(last, reason: reason) }
            return .failed(reason)

        case .needsAuthentication:
            // Deliberately *not* softened into stale: the user must act, and a
            // plausible-looking number would hide that.
            log.warning("usage refresh needs authentication", ["provider": provider.id])
            return .needsAuthentication

        case .notInstalled, .unsupported, .loading, .stale:
            return result
        }
    }

    private func applyBackoff(retryAfter: TimeInterval?) {
        let step = retryAfter ?? currentBackoff
        backoffUntil = now().addingTimeInterval(step)
        currentBackoff = min(currentBackoff * 2, config.maximumBackoff)
    }

    private func resetBackoff() {
        backoffUntil = nil
        currentBackoff = config.initialBackoff
    }

    private func publish(_ newState: ProviderState) {
        state = newState
        for observer in observers { observer(newState) }
    }

    /// Re-evaluates staleness locally, without touching the network. Called by the
    /// UI timer so a snapshot visibly ages even while offline.
    public func reevaluateStaleness() {
        guard case .ready(let snapshot) = state else { return }
        if snapshot.isStale(now: now(), threshold: config.staleThreshold) {
            publish(.stale(snapshot, reason: "aged"))
        }
    }

    public var refreshInterval: TimeInterval { config.refreshInterval }
    public var lastSuccessfulFetch: Date? { lastGoodSnapshot?.fetchedAt }
}
