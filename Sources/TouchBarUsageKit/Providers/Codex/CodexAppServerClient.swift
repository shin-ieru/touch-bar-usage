import Foundation

/// What a usage read produced. Mirrors the Claude client's outcome type so both
/// providers map failures the same way.
public enum CodexFetchOutcome {
    case success([String: Any])
    case notInstalled
    case loggedOut
    case launchFailed
    case timedOut
    case failed(String)
}

public protocol CodexAppServerClienting: Sendable {
    func readRateLimits() async -> CodexFetchOutcome
    func shutdown() async
}

/// Speaks to the local Codex App Server.
///
/// ## Trust boundary
///
/// ```
/// Touch Bar Usage  ──local stdio JSON-RPC──▶  Codex App Server  ──▶  OpenAI
/// ```
///
/// **This app never sees an OpenAI token.** It does not read `~/.codex/auth.json`
/// and holds no OpenAI credential of any kind; the App Server owns authentication
/// and performs the network call itself. All we exchange is a local pipe carrying
/// usage percentages. See docs/security-model.md.
///
/// ## Read-only
///
/// Only `initialize`, `initialized` and `account/rateLimits/read` are ever sent.
/// The server also exposes `account/rateLimitResetCredit/consume` and
/// `account/sendAddCreditsNudgeEmail`; those spend the user's credits or email
/// them, and this monitor must never call them.
public actor CodexAppServerClient: CodexAppServerClienting {

    /// Methods this client is permitted to send. Anything else is a bug.
    public static let allowedMethods = ["initialize", "initialized", "account/rateLimits/read"]
    static let rateLimitsMethod = "account/rateLimits/read"
    static let rateLimitsUpdatedNotification = "account/rateLimits/updated"

    private let resolver: CodexExecutableResolving
    private let log = Log(category: "codex")
    private var transport: CodexJSONRPCTransport?
    private var didInitialize = false
    /// Latest snapshot pushed by the server, used to short-circuit a poll.
    private var pushedPayload: [String: Any]?

    public init(resolver: CodexExecutableResolving = CodexExecutableResolver()) {
        self.resolver = resolver
    }

    public func isInstalled() -> Bool { resolver.executablePath() != nil }
    public func executablePath() -> String? { resolver.executablePath() }

    // MARK: - Connection

    /// Starts the child process and completes the handshake once. The process is
    /// long-lived; subsequent reads reuse it.
    private func connect() async throws -> CodexJSONRPCTransport {
        if let transport, await transport.isRunning, didInitialize {
            return transport
        }
        didInitialize = false

        guard let path = resolver.executablePath() else { throw TransportError.notRunning }
        let transport = CodexJSONRPCTransport(executablePath: path)
        try await transport.start()

        await transport.setNotificationHandler { [weak self] method, payload in
            guard method == CodexAppServerClient.rateLimitsUpdatedNotification,
                  let payload,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { return }
            Task { await self?.storePushedPayload(object) }
        }

        _ = try await transport.request(
            method: "initialize",
            params: ["clientInfo": ["name": "touch-bar-usage", "version": "0.2.0"]])
        try await transport.notify(method: "initialized")

        self.transport = transport
        didInitialize = true
        log.info("codex app server connected")
        return transport
    }

    private func storePushedPayload(_ payload: [String: Any]) {
        pushedPayload = payload
        log.debug("codex rate limits pushed by server")
    }

    // MARK: - Read

    public func readRateLimits() async -> CodexFetchOutcome {
        guard resolver.executablePath() != nil else { return .notInstalled }

        do {
            let transport = try await connect()
            guard let data = try await transport.request(method: Self.rateLimitsMethod) else {
                return .failed("empty response")
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("unexpected usage format")
            }
            return .success(object)
        } catch TransportError.launchFailed {
            return .launchFailed
        } catch TransportError.timedOut {
            // A wedged server should not stay wedged; drop it so the next read
            // starts a fresh child.
            await resetConnection()
            return .timedOut
        } catch TransportError.childExited {
            await resetConnection()
            return .failed("app server exited")
        } catch TransportError.rpc(let message) {
            if Self.looksLikeLoggedOut(message) { return .loggedOut }
            return .failed(Self.sanitize(message))
        } catch {
            await resetConnection()
            return .failed("app server unavailable")
        }
    }

    /// The server reports auth problems as RPC errors rather than a distinct
    /// code, so the message is matched — conservatively, since a wrong guess
    /// would tell the user to sign in when something else is broken.
    static func looksLikeLoggedOut(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let markers = ["not logged in", "logged out", "unauthenticated", "unauthorized",
                       "no account", "requires login", "auth"]
        return markers.contains { lowered.contains($0) }
    }

    /// Server messages may quote account details; keep only a short, generic
    /// summary so nothing identifying reaches a log or the diagnostics window.
    static func sanitize(_ message: String) -> String {
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
        return String(firstLine.prefix(80))
    }

    private func resetConnection() async {
        if let transport { await transport.stop() }
        transport = nil
        didInitialize = false
    }

    public func shutdown() async {
        await resetConnection()
        log.info("codex app server shut down")
    }

    // MARK: - Shared instance

    /// One connection per app: the child process is a shared resource and two
    /// clients would mean two servers.
    public static let shared = CodexAppServerClient()

    /// Called from application termination so no orphan child is left behind.
    public static func shutdownShared() {
        // Detached because termination handlers are synchronous; the process is
        // also terminated by the OS, this just makes it deterministic.
        Task.detached { await CodexAppServerClient.shared.shutdown() }
    }
}
