import Foundation

/// The contract every provider implements. See docs/provider-contract.md.
///
/// A provider is responsible for discovering its own credentials, talking to its
/// own backend, and mapping the result onto `ProviderState`. It must never
/// surface credentials, headers, or raw payloads to callers, and must never
/// throw — every failure is expressed as a `ProviderState` case.
public protocol UsageProvider: Sendable {
    /// Stable identifier used in caches and logs (e.g. "claude").
    var id: String { get }
    /// Human-facing name used in the UI (e.g. "Claude").
    var displayName: String { get }

    /// Perform one read-only usage fetch. Must not prompt the user, must not
    /// mutate stored credentials, and must not throw.
    func fetchUsage() async -> ProviderState

    /// Non-sensitive facts for the diagnostics window. Implementations must not
    /// include tokens, account identifiers, or raw responses.
    func diagnostics() async -> [DiagnosticEntry]
}

public struct DiagnosticEntry: Equatable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}
