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
        env["CLAUDE_CODE_DISABLE_AUTOUPDATER"] = "1"
        env["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
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
        let cancellation = ClaudeCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = ClaudeChildEnvironment.sanitized()
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory ?? NSTemporaryDirectory())
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    do { try process.run() } catch { continuation.resume(returning: nil); return }
                    try? pipe.fileHandleForWriting.close()
                    var result: (output: String, status: Int32)?
                    defer {
                        ClaudeProcessCleanup.stop(process)
                        try? pipe.fileHandleForReading.close()
                        continuation.resume(returning: result)
                    }
                    var output = Data()
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    while !cancellation.cancelled && ProcessInfo.processInfo.systemUptime < deadline {
                        var fd = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                        if poll(&fd, 1, 100) > 0 {
                            var bytes = [UInt8](repeating: 0, count: 8192)
                            let count = Darwin.read(fd.fd, &bytes, bytes.count)
                            if count <= 0 {
                                if !process.isRunning {
                                    process.waitUntilExit()
                                    result = (String(decoding: output, as: UTF8.self), process.terminationStatus)
                                    return
                                }
                                Thread.sleep(forTimeInterval: 0.02)
                            }
                            if count > 0 { output.append(contentsOf: bytes.prefix(count)) }
                            if output.count > 65536 { break }
                        }
                    }
                }
            }
        }, onCancel: { cancellation.cancel() })
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
    /// Settings do not bypass global onboarding. If setup is incomplete the
    /// probe aborts; the user completes setup in their own terminal.
    public static let noToolArguments = [
        "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        "--setting-sources", "", "--no-chrome",
        "--settings", #"{"theme":"dark","disableAllHooks":true}"#,
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
        guard command == "/usage" else { return .launchFailed }
        let cancellation = ClaudeCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: self.drive(command, executable: executable,
                        workingDirectory: workingDirectory, cancellation: cancellation))
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private func drive(_ command: String,
                       executable: String,
                       workingDirectory: String, cancellation: ClaudeCancellation) -> ClaudeCLISessionResult {
        var primary: Int32 = 0, secondary: Int32 = 0
        var window = winsize(ws_row: 50, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &window) == 0 else { return .launchFailed }
        let environment = ClaudeChildEnvironment.sanitized(extra: [
            "TERM": "xterm-256color", "COLUMNS": "120", "LINES": "50",
        ])
        let argv = ([executable] + Self.noToolArguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_adddup2(&actions, secondary, fd)
        }
        posix_spawn_file_actions_addclose(&actions, primary)
        posix_spawn_file_actions_addclose(&actions, secondary)
        // `_np` unconditionally: it is the Darwin spelling and has existed since
        // macOS 10.15, so it covers the whole supported range.
        //
        // The unsuffixed POSIX-2024 name only exists in newer SDKs, and selecting
        // it behind `#available` does not help — that is a *runtime* check, so
        // both branches must still compile. Guarding it that way built here on
        // the macOS 26 SDK and failed on CI's older one.
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGTTIN, SIGTTOU] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF |
                                                   POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(secondary)
        guard status == 0 else { close(primary); return .launchFailed }

        defer { terminate(pid: pid, fd: primary) }

        var buffer = Data()
        var didSend = false
        var sentAt = Date.distantFuture
        var handledSetup = Set<SetupScreen>()
        let deadline = Date().addingTimeInterval(readyTimeout)

        while !cancellation.cancelled && (didSend ? Date().timeIntervalSince(sentAt) < commandTimeout : Date() < deadline) {
            guard let chunk = read(fd: primary, timeout: 0.5) else { break }
            buffer.append(chunk)
            if buffer.count > 2 * 1024 * 1024 { return .timedOut }

            let text = String(decoding: buffer, as: UTF8.self)

            // A fresh probe directory means Claude Code runs its first-run setup.
            // Only screens we positively recognise are answered, each at most
            // once; anything else is left alone and the probe simply times out
            // rather than pressing Enter through an unknown consent screen.
            let latest = ClaudeUsageCLIParser.collapsed(String(text.suffix(6000)))
            if !didSend && (latest.contains("selectloginmethod") || latest.contains("choosethetextstyle")) {
                return .timedOut
            }
            if !didSend, let screen = Self.setupScreen(in: text, directory: workingDirectory), !handledSetup.contains(screen) {
                handledSetup.insert(screen)
                log.debug("answering claude setup screen", ["screen": screen.rawValue])
                Thread.sleep(forTimeInterval: 1.0)
                _ = screen.response.withCString { write(primary, $0, strlen($0)) }
                // Let the next screen paint before deciding anything else.
                Thread.sleep(forTimeInterval: 1.2)
                continue
            }

            if !didSend, Self.looksReady(text) {
                // A moment for the first paint to settle before typing.
                Thread.sleep(forTimeInterval: 1.0)
                _ = command.withCString { write(primary, $0, strlen($0)) }
                Thread.sleep(forTimeInterval: 0.3)
                _ = "\r".withCString { write(primary, $0, 1) }
                didSend = true
                sentAt = Date()
                log.debug("sent slash command to claude session")
            }
            if didSend, Date().timeIntervalSince(sentAt) > commandTimeout { break }
            // Once the panel has rendered there is nothing more to wait for.
            if didSend, Date().timeIntervalSince(sentAt) > 2.5, Self.looksComplete(text) { break }
        }

        let text = String(decoding: buffer, as: UTF8.self)
        if !didSend { return text.isEmpty ? .launchFailed : .timedOut }
        return .output(text)
    }

    /// First-run setup screens the probe knows how to get past.
    ///
    /// Deliberately a closed set. Each is matched on its own wording, answered
    /// once, and nothing else is ever answered — an unrecognised prompt must not
    /// be dismissed blindly, because it might be asking for consent.
    enum SetupScreen: String, Hashable {
        case trustProbeDirectory

        /// Keystrokes that accept the safe default.
        var response: String {
            switch self {
            case .trustProbeDirectory: return "\r"
            }
        }
    }

    static func setupScreen(in text: String, directory: String) -> SetupScreen? {
        // Matched on whitespace-collapsed text: the TUI lays words out with
        // cursor moves, so "choose the text style" arrives as one run of
        // characters once escapes are stripped.
        let tail = ClaudeUsageCLIParser.collapsed(String(text.suffix(6000)))
        func has(_ needle: String) -> Bool { tail.contains(ClaudeUsageCLIParser.collapsed(needle)) }

        // Trust is a consent screen, so it is answered only when the path shown is
        // our own empty probe directory.
        if has("do you trust the files"), has(directory) {
            return .trustProbeDirectory
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
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        var status: Int32 = 0
        // Give it a moment to exit cleanly, then insist.
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) != 0 { close(fd); return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(-pid, SIGKILL)
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
