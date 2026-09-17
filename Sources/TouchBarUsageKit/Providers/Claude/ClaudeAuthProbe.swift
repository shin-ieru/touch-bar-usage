import Foundation
import CoreFoundation

/// Runs a short-lived command and returns its output. Injected so the provider
/// can be tested without spawning anything.
public protocol CommandRunning: Sendable {
    /// Returns stdout and the exit status, or nil on timeout/launch failure.
    func run(executable: String,
             arguments: [String],
             workingDirectory: String?,
             timeout: TimeInterval) async -> (output: String, status: Int32)?
}

/// Asks Claude Code whether it is signed in.
///
/// `claude auth status --json` is a plain subcommand: it exits immediately, sends
/// no model prompt, uses no tools, and starts no session. That makes it a far
/// better oracle than reading the interactive UI, and it is the **only** input
/// permitted to conclude the user is logged out.
public struct ClaudeAuthProbe: Sendable {

    public static let arguments = ["auth", "status", "--json"]

    private let resolver: ClaudeInstallationProbing
    private let runner: CommandRunning
    private let timeout: TimeInterval
    private let log = Log(category: "claude-auth")

    public init(resolver: ClaudeInstallationProbing = ClaudeInstallationProbe(),
                runner: CommandRunning = ProcessCommandRunner(),
                timeout: TimeInterval = 15) {
        self.resolver = resolver
        self.runner = runner
        self.timeout = timeout
    }

    public func authState() async -> ClaudeAuthState {
        guard let executable = resolver.executablePath() else {
            return .notInstalled
        }
        guard let result = await runner.run(executable: executable,
                                            arguments: Self.arguments,
                                            workingDirectory: nil,
                                            timeout: timeout) else {
            // A timeout is not a logout. Saying so would be the original bug in a
            // new place.
            log.warning("claude auth status did not complete")
            return .unknown("auth probe timed out")
        }
        return Self.parse(output: result.output, status: result.status)
    }

    /// Parses `claude auth status --json`.
    ///
    /// Only `loggedIn` is read. The payload also carries an email, organisation
    /// name and organisation id; none of them are extracted, so they cannot reach
    /// a log, the cache, or the diagnostics window.
    public static func parse(output: String, status: Int32) -> ClaudeAuthState {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["loggedIn"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return .unknown("unrecognised auth output")
        }
        let loggedIn = value.boolValue
        if status == 0 && loggedIn { return .loggedIn }
        if status == 1 && !loggedIn { return .loggedOut }
        return .unknown("inconsistent auth result")
    }

}

/// Test double.
public struct StubCommandRunner: CommandRunning {
    private let handler: @Sendable (String, [String]) -> (String, Int32)?
    public init(_ handler: @escaping @Sendable (String, [String]) -> (String, Int32)?) {
        self.handler = handler
    }
    public init(output: String, status: Int32 = 0) {
        self.handler = { _, _ in (output, status) }
    }
    public static var timingOut: StubCommandRunner { StubCommandRunner { _, _ in nil } }

    public func run(executable: String, arguments: [String],
                    workingDirectory: String?, timeout: TimeInterval) async -> (output: String, status: Int32)? {
        handler(executable, arguments).map { (output: $0.0, status: $0.1) }
    }
}
