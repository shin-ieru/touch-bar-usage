import Foundation

public protocol ClaudeUsageProbing: Sendable {
    /// Reads usage from Claude Code's own `/usage`. Returns nil when the probe
    /// could not produce numbers; throws when the UI shows a login screen (not authoritative authentication evidence).
    func fetchUsage(fetchedAt: Date) async throws -> UsageSnapshot?
}

/// Compatibility source: isolated PTY, no tools, hooks, MCP or model prompts.
/// A login screen is only a failed probe; auth status makes the logout decision.
public struct ClaudeUsageProbe: ClaudeUsageProbing {

    /// A directory of our own, containing no user code, so no project settings,
    /// history or tool permissions can leak into the probe.
    public static func defaultProbeDirectory(
        bundleIdentifier: String = "Touch Bar Usage"
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

    public static var isEnabled: Bool { true }

    public func fetchUsage(fetchedAt: Date = Date()) async throws -> UsageSnapshot? {
        guard enabled else { return nil }
        guard let executable = resolver.executablePath() else { return nil }
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)

        let result = await session.runSlashCommand("/usage",
                                                   executable: executable,
                                                   workingDirectory: probeDirectory.path)

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
                // The provider separately confirms auth status; this UI is not authoritative.
                throw ClaudeUsageCLIParser.ParseError.loginRequired
            } catch {
                log.warning("claude usage output could not be parsed")
                return nil
            }
        }
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
