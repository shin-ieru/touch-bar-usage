import Foundation

public actor ClaudeSourceRecorder {
    public private(set) var source: ClaudeUsageSource?
    public private(set) var auth: ClaudeAuthState = .unknown("not checked")
    public private(set) var lastSuccess: Date?
    public private(set) var state = "not yet fetched"
    public init() {}
    func record(source: ClaudeUsageSource?, state: ProviderState, auth: ClaudeAuthState? = nil) {
        self.source = source
        self.state = state.diagnosticLabel
        if let auth { self.auth = auth }
        if case .ready(let snapshot) = state { lastSuccess = snapshot.fetchedAt }
    }
    public func summary() -> String { source?.diagnosticDescription ?? "unavailable" }
}

/// Claude owns authentication, refresh and network access. Only its auth-status
/// command can produce Sign in. The coordinator preserves last-good snapshots.
public struct ClaudeUsageProvider: UsageProvider {
    public let id = "claude"
    public let displayName = "Claude"
    private let installation: ClaudeInstallationProbing
    private let authProbe: ClaudeAuthProbe
    private let control: ClaudeUsageProbing
    private let usageProbe: ClaudeUsageProbing
    private let recorder: ClaudeSourceRecorder
    private let now: @Sendable () -> Date

    public init(installation: ClaudeInstallationProbing = ClaudeInstallationProbe(),
                authProbe: ClaudeAuthProbe? = nil,
                control: ClaudeUsageProbing? = nil,
                usageProbe: ClaudeUsageProbing? = nil,
                recorder: ClaudeSourceRecorder = ClaudeSourceRecorder(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.installation = installation
        self.authProbe = authProbe ?? ClaudeAuthProbe(resolver: installation)
        self.control = control ?? ClaudeCLIUsageClient(resolver: installation)
        self.usageProbe = usageProbe ?? ClaudeUsageProbe(resolver: installation)
        self.recorder = recorder
        self.now = now
    }
    public var sourceRecorder: ClaudeSourceRecorder { recorder }

    public func fetchUsage() async -> ProviderState {
        guard installation.isInstalled() else { return .notInstalled }
        for (probe, source) in [(control, ClaudeUsageSource.controlProtocol), (usageProbe, .cli)] {
            if Task.isCancelled { return .failed("Claude refresh cancelled") }
            if let snapshot = try? await probe.fetchUsage(fetchedAt: now()) {
                let state = ProviderState.ready(snapshot)
                await recorder.record(source: source, state: state)
                return state
            }
        }
        if Task.isCancelled { return .failed("Claude refresh cancelled") }
        let auth = await authProbe.authState()
        let state: ProviderState
        if auth.isConfirmedLoggedOut {
            state = .needsAuthentication
        } else {
            state = .failed(auth == .loggedIn
                ? "Claude is signed in; live usage refresh is temporarily unavailable."
                : "Claude usage unavailable; authentication status could not be confirmed.")
        }
        await recorder.record(source: await recorder.lastSuccess == nil ? nil : .staleCache, state: state, auth: auth)
        return state
    }

    public func diagnostics() async -> [DiagnosticEntry] {
        let auth = await recorder.auth
        let authLabel: String
        switch auth {
        case .loggedIn: authLabel = "logged in"
        case .loggedOut: authLabel = "logged out"
        case .notInstalled: authLabel = "not installed"
        case .unknown: authLabel = "unknown / not checked"
        }
        var entries: [DiagnosticEntry] = [
            .init(label: "Claude CLI", value: installation.isInstalled() ? "installed" : "not found"),
            .init(label: "Claude auth status", value: authLabel),
            .init(label: "Claude usage source", value: await recorder.summary()),
            .init(label: "Claude provider state", value: await recorder.state),
            .init(label: "Claude credentials", value: "owned exclusively by Claude Code"),
        ]
        if let client = control as? ClaudeCLIUsageClient {
            entries.append(.init(label: "Claude version", value: await client.currentVersion))
            entries.append(.init(label: "get_usage support", value: await client.support))
        }
        if let date = await recorder.lastSuccess {
            entries.append(.init(label: "Claude last successful refresh", value: ISO8601DateFormatter().string(from: date)))
        }
        return entries
    }
}

// MARK: - Installation probe

public protocol ClaudeInstallationProbing: Sendable {
    func isInstalled() -> Bool
    func executablePath() -> String?
}

/// Looks for the Claude Code CLI in its known install locations. Does not execute
/// it — presence is all this needs to decide.
public struct ClaudeInstallationProbe: ClaudeInstallationProbing {
    private let candidates: [String]?
    public init(candidates: [String]? = nil) { self.candidates = candidates }

    public func executablePath() -> String? {
        let manager = FileManager.default
        if let candidates { return candidates.first { manager.isExecutableFile(atPath: $0) } }
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TBU_CLAUDE_PATH"], manager.isExecutableFile(atPath: override) { return override }
        let home = NSHomeDirectory()
        var paths = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        for root in [".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions"] {
            let directory = URL(fileURLWithPath: home).appendingPathComponent(root)
            for entry in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where entry.lastPathComponent.hasPrefix("anthropic.claude-code-") {
                paths.append(entry.appendingPathComponent("resources/native-binary/claude").path)
            }
        }
        return paths.filter { manager.isExecutableFile(atPath: $0) }.sorted { a, b in
            let left = Self.versionHint(a), right = Self.versionHint(b)
            return left.compare(right, options: .numeric) == .orderedDescending
        }.first
    }

    /// Installation layout is a selection hint only. Capability caching always
    /// uses the chosen binary's real --version output, queried on every refresh.
    static func versionHint(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let range = resolved.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return "0.0.0" }
        return String(resolved[range])
    }
    public func isInstalled() -> Bool { executablePath() != nil }
}
