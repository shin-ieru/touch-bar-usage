import Foundation

/// Exists to prove the `UsageProvider` abstraction is genuinely provider-agnostic
/// and to drive tests and preview rendering. Not shipped in the UI.
///
/// An actor rather than a locked class so it can record overlap safely: the
/// refresh-coalescing tests assert `maxConcurrent == 1`.
public actor MockUsageProvider: UsageProvider {
    public nonisolated let id: String
    public nonisolated let displayName: String

    private var queued: [ProviderState]
    private let fallback: ProviderState
    private let delay: TimeInterval

    public private(set) var fetchCount = 0
    public private(set) var maxConcurrent = 0
    private var inFlight = 0

    public init(
        id: String = "mock",
        displayName: String = "Mock",
        states: [ProviderState] = [],
        fallback: ProviderState = .failed("no state queued"),
        delay: TimeInterval = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.queued = states
        self.fallback = fallback
        self.delay = delay
    }

    public func fetchUsage() async -> ProviderState {
        fetchCount += 1
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        let next = queued.isEmpty ? fallback : queued.removeFirst()

        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        inFlight -= 1
        return next
    }

    public func diagnostics() async -> [DiagnosticEntry] {
        [DiagnosticEntry(label: "Mock provider", value: "fetches: \(fetchCount)")]
    }
}

/// Deterministic HTTP double for provider tests — no network, no credentials.
public struct StubHTTPClient: UsageHTTPClient {
    private let outcome: @Sendable (String) -> UsageFetchOutcome
    public init(_ outcome: @escaping @Sendable (String) -> UsageFetchOutcome) {
        self.outcome = outcome
    }
    public init(always outcome: UsageFetchOutcome) {
        self.outcome = { _ in outcome }
    }
    public func fetchUsage(accessToken: String) async -> UsageFetchOutcome {
        outcome(accessToken)
    }
}

/// Credential double. Holds an obviously fake token so a leak in tests is inert.
public struct StubCredentialReader: ClaudeCredentialReading {
    public static let fakeToken = "test-token-not-a-real-credential"
    private let result: Result<ClaudeCredential, CredentialError>

    public init(token: String = StubCredentialReader.fakeToken, expiresAt: Date? = nil) {
        self.result = .success(ClaudeCredential(accessToken: token, expiresAt: expiresAt))
    }
    public init(error: CredentialError) {
        self.result = .failure(error)
    }
    public func readCredential() throws -> ClaudeCredential {
        try result.get()
    }
}

public struct StubInstallationProbe: ClaudeInstallationProbing {
    private let installed: Bool
    public init(installed: Bool) { self.installed = installed }
    public func isInstalled() -> Bool { installed }
    public func executablePath() -> String? { installed ? "/stub/claude" : nil }
}
