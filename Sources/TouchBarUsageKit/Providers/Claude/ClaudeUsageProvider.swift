import Foundation

/// Records which source last served Claude usage, for Diagnostics.
public actor ClaudeSourceRecorder {
    public private(set) var source: ClaudeUsageSource?
    public private(set) var oauthFailure: ClaudeOAuthFailure?

    public init() {}

    func record(source: ClaudeUsageSource, oauthFailure: ClaudeOAuthFailure?) {
        self.source = source
        self.oauthFailure = oauthFailure
    }

    public func summary() -> String {
        guard let source else { return "not yet fetched" }
        guard let oauthFailure, source != .oauth else { return source.diagnosticDescription }
        return "\(source.diagnosticDescription) (OAuth unavailable: \(oauthFailure.diagnosticDescription))"
    }
}

/// Claude Code usage provider.
///
/// ## Why there are two sources
///
/// v0.1.0 read the OAuth access token from Claude Code's keychain item and, if
/// anything about that failed, reported `needsAuthentication` — which the UI
/// shows as **Sign in**. That conflated two very different things:
///
/// - Touch Bar Usage could not *use* the credential;
/// - the user is actually logged out.
///
/// The first happens routinely. Claude Code refreshes its access token lazily,
/// when Claude Code itself next runs, so between expiry and that refresh the
/// stored token is stale while the account is perfectly fine. v0.1.0 told those
/// users to sign in. See docs/claude-auth-resilience.md.
///
/// ## Strategy
///
/// ```
/// OAuth fast path                → ready (oauth)
/// ├─ fails → claude auth status
/// │    ├─ logged out             → needsAuthentication   ← the only route
/// │    └─ logged in / unknown
/// │         ├─ retry OAuth once  → ready (oauth)
/// │         ├─ CLI /usage probe  → ready (cli)
/// │         └─ neither           → failed  (coordinator keeps last good, stale)
/// ```
///
/// The invariant, asserted in tests: **an OAuth failure alone never produces
/// `needsAuthentication`.**
///
/// Claude Code owns authentication throughout. This provider never reads the
/// refresh token, never exchanges or rotates it, and never writes to the keychain.
public struct ClaudeUsageProvider: UsageProvider {
    public let id = ClaudeUsageParser.providerID
    public let displayName = "Claude"

    private let credentials: ClaudeCredentialReading
    private let client: UsageHTTPClient
    private let installation: ClaudeInstallationProbing
    private let authProbe: ClaudeAuthProbe
    private let usageProbe: ClaudeUsageProbing
    private let recorder: ClaudeSourceRecorder
    private let keychainGate: ClaudeKeychainGate
    private let now: @Sendable () -> Date
    private let log = Log(category: "claude")

    public init(
        credentials: ClaudeCredentialReading = KeychainClaudeCredentialReader(),
        client: UsageHTTPClient = AnthropicUsageClient(),
        installation: ClaudeInstallationProbing = ClaudeInstallationProbe(),
        authProbe: ClaudeAuthProbe? = nil,
        usageProbe: ClaudeUsageProbing? = nil,
        recorder: ClaudeSourceRecorder = ClaudeSourceRecorder(),
        keychainGate: ClaudeKeychainGate = ClaudeKeychainGate(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        // Wrapped so a keychain ACL dialog can never hang a refresh.
        self.credentials = credentials is TimeLimitedCredentialReader
            ? credentials : TimeLimitedCredentialReader(credentials)
        self.client = client
        self.installation = installation
        self.authProbe = authProbe ?? ClaudeAuthProbe(resolver: installation)
        self.usageProbe = usageProbe ?? ClaudeUsageProbe(resolver: installation)
        self.recorder = recorder
        self.keychainGate = keychainGate
        self.now = now
    }

    public var sourceRecorder: ClaudeSourceRecorder { recorder }

    public func fetchUsage() async -> ProviderState {
        // 1. OAuth fast path. Attempted regardless of the locally computed expiry:
        //    the server decides whether a token works, and the local clock is not
        //    evidence of anything.
        switch await attemptOAuth() {
        case .success(let snapshot):
            await recorder.record(source: .oauth, oauthFailure: nil)
            return .ready(snapshot)

        case .transient(let state):
            // Offline or rate limited: nothing to do with authentication, and the
            // CLI would fail the same way. Report as-is.
            return state

        case .failure(let reason):
            return await fallback(after: reason)
        }
    }

    // MARK: - OAuth fast path

    private enum OAuthOutcome {
        case success(UsageSnapshot)
        case transient(ProviderState)
        case failure(ClaudeOAuthFailure)
    }

    private func attemptOAuth() async -> OAuthOutcome {
        // Skip entirely while the keychain is known to be unavailable, so a
        // background refresh cannot re-trigger the ACL dialog every five minutes.
        guard await keychainGate.shouldAttempt() else {
            return .failure(.keychainAccessDenied)
        }

        let credential: ClaudeCredential
        do {
            credential = try credentials.readCredential()
            await keychainGate.recordAvailable()
        } catch CredentialError.notFound {
            return .failure(.credentialNotFound)
        } catch CredentialError.accessDenied {
            // Either an ACL prompt we cannot answer from a background app, or one
            // still on screen when the read timed out. Not a logout, and pausing
            // stops it becoming a recurring interruption.
            await keychainGate.recordUnavailable()
            return .failure(.keychainAccessDenied)
        } catch {
            return .failure(.credentialUnreadable)
        }

        if credential.isExpired(now: now()) {
            // Recorded, not acted on. Claude Code will refresh this itself; the
            // request is still attempted in case the local clock is wrong.
            log.debug("claude access token past its stated expiry; trying anyway")
        }

        switch await client.fetchUsage(accessToken: credential.accessToken) {
        case .success(let data):
            do {
                return .success(try ClaudeUsageParser.parse(data: data, fetchedAt: now()))
            } catch {
                return .failure(.unexpectedFormat)
            }
        case .unauthorized:
            return .failure(.tokenRejected)
        case .rateLimited(let retryAfter):
            return .transient(.rateLimited(retryAfter: retryAfter))
        case .offline:
            return .transient(.offline)
        case .httpError:
            return .failure(.httpError)
        case .transportError:
            return .transient(.offline)
        }
    }

    // MARK: - Fallback

    private func fallback(after failure: ClaudeOAuthFailure) async -> ProviderState {
        guard installation.isInstalled() else {
            // Nothing installed: no credential and no CLI to ask. This is the one
            // case where "not installed" is the honest answer.
            await recorder.record(source: .staleCache, oauthFailure: failure)
            return .notInstalled
        }

        log.info("claude oauth path unavailable; consulting claude code",
                 ["reason": failure.diagnosticDescription])

        // 2. The only question that can justify "Sign in".
        let authState = await authProbe.authState()
        if authState.isConfirmedLoggedOut {
            log.info("claude code reports signed out")
            await recorder.record(source: .staleCache, oauthFailure: failure)
            return .needsAuthentication
        }

        // 3. Running the CLI often prompts Claude Code to refresh its own
        //    credential, so the fast path is worth one more try. This is Claude
        //    Code renewing its token, not us: we only re-read the result.
        if case .success(let snapshot) = await attemptOAuth() {
            log.info("claude oauth recovered after auth probe")
            await recorder.record(source: .oauth, oauthFailure: failure)
            return .ready(snapshot)
        }

        // 4. Read the numbers from Claude Code's own /usage.
        do {
            if let snapshot = try await usageProbe.fetchUsage(fetchedAt: now()) {
                await recorder.record(source: .cli, oauthFailure: failure)
                return .ready(snapshot)
            }
        } catch ClaudeUsageCLIParser.ParseError.loginRequired {
            // The CLI itself showed a login screen — a confirmed logout.
            log.info("claude cli reports login required")
            await recorder.record(source: .staleCache, oauthFailure: failure)
            return .needsAuthentication
        } catch {
            // Any other probe error is just a failed probe.
        }

        // 5. Both live sources failed but the user is not known to be logged out.
        //    The coordinator keeps the last good snapshot and marks it stale; if
        //    there is none, the user sees an honest failure — never "Sign in".
        await recorder.record(source: .staleCache, oauthFailure: failure)
        log.warning("claude usage unavailable from both sources",
                    ["reason": failure.diagnosticDescription])
        return .failed(failure.diagnosticDescription)
    }

    // MARK: - Diagnostics

    public func diagnostics() async -> [DiagnosticEntry] {
        var entries: [DiagnosticEntry] = []
        entries.append(.init(label: "Claude Code", value: installation.isInstalled() ? "installed" : "not found"))

        do {
            let credential = try credentials.readCredential()
            entries.append(.init(label: "Claude credential", value: "found"))
            if let expiry = credential.expiresAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let valid = !credential.isExpired(now: now())
                entries.append(.init(
                    label: "Claude token",
                    value: valid
                        ? "valid (expires \(formatter.localizedString(for: expiry, relativeTo: now())))"
                        // Not an error: Claude Code refreshes this when it next runs.
                        : "past expiry — Claude Code refreshes this itself"))
            } else {
                entries.append(.init(label: "Claude token", value: "unknown expiry"))
            }
        } catch CredentialError.notFound {
            entries.append(.init(label: "Claude credential", value: "not found"))
        } catch CredentialError.accessDenied {
            entries.append(.init(label: "Claude credential", value: "access denied"))
        } catch {
            entries.append(.init(label: "Claude credential", value: "unreadable"))
        }

        entries.append(.init(label: "Claude usage source", value: await recorder.summary()))
        if await keychainGate.isPaused {
            entries.append(.init(label: "Keychain fast path",
                                 value: "paused after a denied prompt; using CLI fallback"))
        }
        entries.append(.init(label: "Usage endpoint", value: AnthropicUsageClient.endpoint.host ?? "unknown"))
        entries.append(.init(label: "Endpoint status", value: "undocumented / experimental"))
        entries.append(.init(label: "Claude refresh token", value: "never read or used"))
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
    private let candidates: [String]

    public init(candidates: [String]? = nil) {
        if let candidates {
            self.candidates = candidates
        } else {
            let home = NSHomeDirectory()
            var paths = [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
            // Also honour PATH, so an unusual install still resolves.
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                paths.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
            }
            self.candidates = paths
        }
    }

    public func executablePath() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func isInstalled() -> Bool { executablePath() != nil }
}
