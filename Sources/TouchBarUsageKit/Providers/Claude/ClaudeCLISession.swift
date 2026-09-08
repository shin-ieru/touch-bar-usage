import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Environment variables cleared before launching any Claude Code child.
///
/// Claude Code refuses to start inside another Claude Code session, and that
/// guard is correct — nested sessions share runtime resources. Touch Bar Usage is
/// not a Claude session, but it can be *launched* from one during development, so
/// the inherited markers are removed rather than relied upon to be absent.
enum ClaudeChildEnvironment {
    static let clearedKeys = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_SSH_AUTH_SOCK",
    ]

    static func sanitized(_ base: [String: String] = ProcessInfo.processInfo.environment,
                          extra: [String: String] = [:]) -> [String: String] {
        var env = base
        for key in clearedKeys { env.removeValue(forKey: key) }
        for (key, value) in extra { env[key] = value }
        return env
    }
}

/// Runs a short-lived command with a bounded timeout.
///
/// Used for `claude auth status`, which is a plain subcommand — no PTY needed.
public struct ProcessCommandRunner: CommandRunning {
    private let log = Log(category: "claude-cli")

    public init() {}

    public func run(executable: String,
                    arguments: [String],
                    workingDirectory: String?,
                    timeout: TimeInterval) async -> (output: String, status: Int32)? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ClaudeChildEnvironment.sanitized()
            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // No stdin: the probe must never sit waiting for input.
            process.standardInput = FileHandle.nullDevice

            // Guarantees exactly one resume across the success and timeout paths.
            let resumed = OneShot()

            do {
                try process.run()
            } catch {
                log.warning("claude command failed to launch")
                if resumed.claim() { continuation.resume(returning: nil) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                log.warning("claude command timed out; terminating")
                process.terminate()
                // The reader below still completes; the timeout only forces exit.
            }

            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                if resumed.claim() {
                    continuation.resume(returning: (output, process.terminationStatus))
                }
            }
        }
    }
}

/// Single-use latch, so a continuation cannot be resumed twice.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - PTY session

/// Result of driving an interactive Claude Code session.
public enum ClaudeCLISessionResult: Equatable, Sendable {
    case output(String)
    case launchFailed
    case timedOut
}

public protocol ClaudeCLISessionRunning: Sendable {
    /// Launches the CLI, waits for it to be ready, sends `command`, collects the
    /// screen for a moment, then exits.
    func runSlashCommand(_ command: String,
                         executable: String,
                         workingDirectory: String) async -> ClaudeCLISessionResult
}

/// Drives Claude Code's interactive UI through a pseudo-terminal.
///
/// A PTY is required only because slash commands are interactive; Claude Code
/// will not render `/usage` on a plain pipe. Nothing here sends a model prompt,
/// enables a tool, or touches the user's projects.
///
/// The child is always terminated and reaped, including on timeout, so no
/// orphaned `claude` process is left behind.
public struct ClaudePTYSession: ClaudeCLISessionRunning {

    /// Tools are disabled explicitly. The probe only needs the command UI.
    ///
    /// `--settings` pre-supplies the theme so Claude Code's first-run picker does
    /// not appear: driving that wizard through a PTY proved unreliable, and not
    /// raising it at all is both simpler and safer than answering setup screens.
    public static let noToolArguments = [
        "--allowed-tools", "",
        "--settings", #"{"theme":"dark"}"#,
    ]

    private let readyTimeout: TimeInterval
    private let commandTimeout: TimeInterval
    private let log = Log(category: "claude-cli")

    public init(readyTimeout: TimeInterval = 25, commandTimeout: TimeInterval = 20) {
        self.readyTimeout = readyTimeout
        self.commandTimeout = commandTimeout
    }

    public func runSlashCommand(_ command: String,
                                executable: String,
                                workingDirectory: String) async -> ClaudeCLISessionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.drive(command,
                                                          executable: executable,
                                                          workingDirectory: workingDirectory))
            }
        }
    }

    private func drive(_ command: String,
                       executable: String,
                       workingDirectory: String) -> ClaudeCLISessionResult {
        var primary: Int32 = 0
        var window = winsize(ws_row: 50, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&primary, nil, nil, &window)
        if pid < 0 { return .launchFailed }

        if pid == 0 {
            // Child. Only async-signal-safe work here.
            _ = workingDirectory.withCString { chdir($0) }
            let environment = ClaudeChildEnvironment.sanitized(extra: [
                "TERM": "xterm-256color", "COLUMNS": "120", "LINES": "50",
                // Keep the probe out of any inherited project context.
                "CLAUDE_CODE_DISABLE_AUTOUPDATER": "1",
            ])
            let arguments = [executable] + Self.noToolArguments
            let argv: [UnsafeMutablePointer<CChar>?] =
                arguments.map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] =
                environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            execve(executable, argv, envp)
            _exit(127)   // execve only returns on failure
        }

        defer { terminate(pid: pid, fd: primary) }

        var buffer = Data()
        var didSend = false
        var sentAt = Date.distantFuture
        var handledSetup = Set<SetupScreen>()
        let deadline = Date().addingTimeInterval(readyTimeout)

        while Date() < deadline {
            guard let chunk = read(fd: primary, timeout: 0.5) else { break }
            buffer.append(chunk)

            let text = String(decoding: buffer, as: UTF8.self)

            // A fresh probe directory means Claude Code runs its first-run setup.
            // Only screens we positively recognise are answered, each at most
            // once; anything else is left alone and the probe simply times out
            // rather than pressing Enter through an unknown consent screen.
            if !didSend, let screen = Self.setupScreen(in: text), !handledSetup.contains(screen) {
                handledSetup.insert(screen)
                log.debug("answering claude setup screen", ["screen": screen.rawValue])
                Thread.sleep(forTimeInterval: 0.6)
                _ = screen.response.withCString { write(primary, $0, strlen($0)) }
                // Let the next screen paint before deciding anything else.
                Thread.sleep(forTimeInterval: 1.2)
                continue
            }

            if !didSend, Self.looksReady(text) {
                // A moment for the first paint to settle before typing.
                Thread.sleep(forTimeInterval: 1.0)
                _ = command.appending("\r").withCString { write(primary, $0, strlen($0)) }
                didSend = true
                sentAt = Date()
                log.debug("sent slash command to claude session")
            }
            if didSend, Date().timeIntervalSince(sentAt) > commandTimeout { break }
            // Once the panel has rendered there is nothing more to wait for.
            if didSend, Date().timeIntervalSince(sentAt) > 2.5, Self.looksComplete(text) { break }
        }

        let text = String(decoding: buffer, as: UTF8.self)
        Self.dumpTranscriptIfRequested(text)
        if !didSend { return text.isEmpty ? .launchFailed : .timedOut }
        return .output(text)
    }

    /// Development affordance: `TBU_PROBE_TRANSCRIPT=<path>` writes the raw PTY
    /// transcript so the readiness heuristics can be tuned against what Claude
    /// Code actually renders. Off unless the variable is set.
    static func dumpTranscriptIfRequested(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["TBU_PROBE_TRANSCRIPT"],
              !path.isEmpty else { return }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// First-run setup screens the probe knows how to get past.
    ///
    /// Deliberately a closed set. Each is matched on its own wording, answered
    /// once, and nothing else is ever answered — an unrecognised prompt must not
    /// be dismissed blindly, because it might be asking for consent.
    enum SetupScreen: String, Hashable {
        case theme
        case pressEnter
        case trustProbeDirectory

        /// Keystrokes that accept the safe default.
        var response: String {
            switch self {
            case .theme, .pressEnter, .trustProbeDirectory: return "\r"
            }
        }
    }

    static func setupScreen(in text: String) -> SetupScreen? {
        // Matched on whitespace-collapsed text: the TUI lays words out with
        // cursor moves, so "choose the text style" arrives as one run of
        // characters once escapes are stripped.
        let tail = ClaudeUsageCLIParser.collapsed(String(text.suffix(6000)))
        func has(_ needle: String) -> Bool { tail.contains(ClaudeUsageCLIParser.collapsed(needle)) }

        if has("choose the text style") || has("run /theme") {
            return .theme
        }
        // Trust is a consent screen, so it is answered only when the path shown is
        // our own empty probe directory.
        if has("do you trust the files"), has("claudeprobe") {
            return .trustProbeDirectory
        }
        if has("press enter to continue") {
            return .pressEnter
        }
        return nil
    }

    /// The prompt is up once Claude Code paints its input hint.
    static func looksReady(_ text: String) -> Bool {
        let collapsed = ClaudeUsageCLIParser.collapsed(String(text.suffix(4000)))
        // The input hint only appears once setup is finished and the prompt is up.
        return collapsed.contains("?forshortcuts")
            || collapsed.contains("bypasspermissions")
    }

    /// Enough of the usage panel has arrived to parse.
    static func looksComplete(_ text: String) -> Bool {
        let collapsed = ClaudeUsageCLIParser.collapsed(text)
        let hasSection = collapsed.contains("currentsession") || collapsed.contains("currentweek")
        return hasSection && collapsed.contains("%")
    }

    private func read(fd: Int32, timeout: TimeInterval) -> Data? {
        var set = fd_set()
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { words in
                for index in 0..<32 { words[index] = 0 }
                words[Int(fd) / 32] |= Int32(1 << (Int(fd) % 32))
            }
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        guard select(fd + 1, &set, nil, nil, &tv) > 0 else { return Data() }

        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else { return nil }   // EOF or error
        return Data(bytes[0..<count])
    }

    /// Always runs: terminate, then reap, so nothing is orphaned.
    private func terminate(pid: pid_t, fd: Int32) {
        kill(pid, SIGTERM)
        var status: Int32 = 0
        // Give it a moment to exit cleanly, then insist.
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) != 0 { close(fd); return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
        close(fd)
    }
}

/// Test double.
public struct StubClaudeCLISession: ClaudeCLISessionRunning {
    private let result: ClaudeCLISessionResult
    public init(_ result: ClaudeCLISessionResult) { self.result = result }
    public func runSlashCommand(_ command: String, executable: String,
                                workingDirectory: String) async -> ClaudeCLISessionResult {
        result
    }
}
