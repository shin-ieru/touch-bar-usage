import Foundation

/// Codex usage provider.
///
/// Reads rate limits from the **local Codex App Server** over stdio JSON-RPC.
/// This app never holds an OpenAI credential: it does not parse
/// `~/.codex/auth.json`, and the App Server performs the authenticated network
/// call on its own behalf. See `CodexAppServerClient` and docs/security-model.md.
///
/// Read-only: only `initialize`, `initialized` and `account/rateLimits/read` are
/// sent. Nothing that spends credits, sends mail, starts a thread, or touches
/// authentication is ever called.
public struct CodexUsageProvider: UsageProvider {
    public let id = CodexUsageParser.providerID
    public let displayName = "Codex"

    private let client: CodexAppServerClienting
    private let resolver: CodexExecutableResolving
    private let now: @Sendable () -> Date
    private let log = Log(category: "codex")

    public init(client: CodexAppServerClienting = CodexAppServerClient.shared,
                resolver: CodexExecutableResolving = CodexExecutableResolver(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.resolver = resolver
        self.now = now
    }

    public func fetchUsage() async -> ProviderState {
        guard resolver.executablePath() != nil else { return .notInstalled }

        switch await client.readRateLimits() {
        case .success(let object):
            do {
                let snapshot = try CodexUsageParser.parse(object: object, fetchedAt: now())
                return .ready(snapshot)
            } catch CodexUsageParser.ParseError.noWindows {
                // The account is reachable but reports no usable window. Saying so
                // is better than inventing zeroes.
                return .failed("no rate limits reported")
            } catch {
                return .failed("unexpected usage format")
            }
        case .notInstalled:
            return .notInstalled
        case .loggedOut:
            return .needsAuthentication
        case .launchFailed:
            return .failed("app server would not start")
        case .timedOut:
            // Treated as transient so the coordinator keeps the last good
            // snapshot and marks it stale, rather than blanking Codex.
            return .offline
        case .failed(let reason):
            return .failed(reason)
        }
    }

    public func diagnostics() async -> [DiagnosticEntry] {
        var entries: [DiagnosticEntry] = []
        let path = resolver.executablePath()
        entries.append(.init(label: "Codex CLI", value: path != nil ? "installed" : "not found"))

        guard path != nil else {
            entries.append(.init(label: "Codex App Server", value: "unavailable"))
            return entries
        }

        switch await client.readRateLimits() {
        case .success(let object):
            entries.append(.init(label: "Codex App Server", value: "connected"))
            entries.append(.init(label: "Codex auth", value: "ready"))
            if let snapshot = try? CodexUsageParser.parse(object: object, fetchedAt: now()) {
                entries.append(.init(label: "Codex 5h window",
                                     value: snapshot.shortWindow != nil ? "reported" : "not reported"))
                entries.append(.init(label: "Codex weekly window",
                                     value: snapshot.weeklyWindow != nil ? "reported" : "not reported"))
                let others = snapshot.windows.filter { $0.category == .other }
                if !others.isEmpty {
                    entries.append(.init(label: "Codex other windows",
                                         value: others.map(\.longLabel).joined(separator: ", ")))
                }
            }
        case .loggedOut:
            entries.append(.init(label: "Codex App Server", value: "connected"))
            entries.append(.init(label: "Codex auth", value: "signed out"))
        case .notInstalled:
            entries.append(.init(label: "Codex App Server", value: "unavailable"))
        case .launchFailed:
            entries.append(.init(label: "Codex App Server", value: "would not start"))
        case .timedOut:
            entries.append(.init(label: "Codex App Server", value: "timed out"))
        case .failed(let reason):
            entries.append(.init(label: "Codex App Server", value: reason))
        }

        entries.append(.init(label: "Codex token access", value: "none — App Server owns auth"))
        return entries
    }
}

/// Test double for the App Server.
public struct StubCodexAppServerClient: CodexAppServerClienting {
    private let outcome: @Sendable () -> CodexFetchOutcome
    public init(_ outcome: @escaping @Sendable () -> CodexFetchOutcome) {
        self.outcome = outcome
    }
    public init(always outcome: CodexFetchOutcome) {
        // `CodexFetchOutcome` carries a dictionary and is not Sendable; capture
        // it through a closure the compiler can verify instead.
        switch outcome {
        case .success(let object):
            let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            self.outcome = {
                let decoded = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
                return .success(decoded ?? [:])
            }
        case .notInstalled: self.outcome = { .notInstalled }
        case .loggedOut:    self.outcome = { .loggedOut }
        case .launchFailed: self.outcome = { .launchFailed }
        case .timedOut:     self.outcome = { .timedOut }
        case .failed(let reason): self.outcome = { .failed(reason) }
        }
    }
    public func readRateLimits() async -> CodexFetchOutcome { outcome() }
    public func shutdown() async {}
}
