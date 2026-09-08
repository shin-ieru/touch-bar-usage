import Foundation

public protocol ClaudeUsageProbing: Sendable {
    /// Reads usage from Claude Code's own `/usage`. Returns nil when the probe
    /// could not produce numbers; throws only to report a confirmed login screen.
    func fetchUsage(fetchedAt: Date) async throws -> UsageSnapshot?
}

/// Reads Claude usage through Claude Code's `/usage` command.
///
/// Used only when the OAuth fast path is unavailable *and* Claude Code says the
/// user is signed in. It exists so a credential Touch Bar Usage cannot read never
/// looks like a logout.
///
/// The session runs in a dedicated empty directory, with tools disabled, and
/// sends nothing but `/usage`. It never runs `/login`, never sends a model
/// prompt, and never touches the user's projects or Claude Code history.
public struct ClaudeUsageProbe: ClaudeUsageProbing {

    /// A directory of our own, containing no user code, so no project settings,
    /// history or tool permissions can leak into the probe.
    public static func defaultProbeDirectory(
        bundleIdentifier: String = "com.gabrielanyog.touchbarusage"
    ) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
    }

    private let resolver: ClaudeInstallationProbing
    private let session: ClaudeCLISessionRunning
    private let probeDirectory: URL
    private let enabled: Bool
    private let log = Log(category: "claude-probe")

    public init(resolver: ClaudeInstallationProbing = ClaudeInstallationProbe(),
                session: ClaudeCLISessionRunning = ClaudePTYSession(),
                probeDirectory: URL = ClaudeUsageProbe.defaultProbeDirectory(),
                enabled: Bool = ClaudeUsageProbe.isEnabled) {
        self.resolver = resolver
        self.session = session
        self.probeDirectory = probeDirectory
        self.enabled = enabled
    }

    /// Opt-in for now.
    ///
    /// The probe is implemented and fixture-tested, but on macOS 26.6.2 with
    /// Claude Code 2.1.62 it does not get past the first-run setup screen that
    /// appears in a fresh probe directory, and each attempt costs ~27 s. Running
    /// that on every refresh would be a real cost for no benefit, so it is off
    /// unless `TBU_CLAUDE_CLI_FALLBACK=1`.
    ///
    /// Nothing depends on it: the fix for the false "Sign in" is the auth-status
    /// oracle, not this. See docs/claude-auth-resilience.md.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TBU_CLAUDE_CLI_FALLBACK"] == "1"
    }

    public func fetchUsage(fetchedAt: Date = Date()) async throws -> UsageSnapshot? {
        guard enabled else { return nil }
        guard let executable = resolver.executablePath() else { return nil }
        prepareProbeDirectory()

        let result = await session.runSlashCommand("/usage",
                                                   executable: executable,
                                                   workingDirectory: probeDirectory.path)
        defer { cleanUpProbeArtifacts() }

        switch result {
        case .launchFailed:
            log.warning("claude usage probe could not launch")
            return nil
        case .timedOut:
            log.warning("claude usage probe timed out")
            return nil
        case .output(let text):
            do {
                let snapshot = try ClaudeUsageCLIParser.parse(output: text, fetchedAt: fetchedAt)
                log.info("claude usage read via cli fallback",
                         ["windows": "\(snapshot.windows.count)"])
                return snapshot
            } catch ClaudeUsageCLIParser.ParseError.loginRequired {
                // A login screen is a real answer; let the caller act on it.
                throw ClaudeUsageCLIParser.ParseError.loginRequired
            } catch {
                log.warning("claude usage output could not be parsed")
                return nil
            }
        }
    }

    private func prepareProbeDirectory() {
        try? FileManager.default.createDirectory(at: probeDirectory,
                                                 withIntermediateDirectories: true)
    }

    /// Removes only what the probe itself left in its own directory.
    ///
    /// Scoped deliberately: normal Claude Code history lives elsewhere and is
    /// never touched. Anything unexpected in the directory is left alone.
    private func cleanUpProbeArtifacts() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: probeDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where Self.isProbeArtifact(entry.lastPathComponent) {
            try? manager.removeItem(at: entry)
        }
    }

    static func isProbeArtifact(_ name: String) -> Bool {
        // Only session/scratch files Claude Code creates in its working directory.
        ["CLAUDE.md", ".claude", ".claude.json"].contains(name)
    }
}

/// Test double.
public struct StubClaudeUsageProbe: ClaudeUsageProbing {
    private let result: Result<UsageSnapshot?, Error>
    public init(snapshot: UsageSnapshot?) { self.result = .success(snapshot) }
    public init(error: Error) { self.result = .failure(error) }
    public func fetchUsage(fetchedAt: Date) async throws -> UsageSnapshot? {
        try result.get()
    }
}
