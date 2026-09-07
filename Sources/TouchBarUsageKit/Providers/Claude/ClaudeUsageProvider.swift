import Foundation

/// Claude Code usage provider.
///
/// Flow: read the existing Claude Code access token from the keychain → one
/// read-only GET → normalize. The token is never cached, logged, or written
/// anywhere; the refresh token is never read at all. If the token is expired the
/// provider reports `.needsAuthentication` and the user re-authenticates inside
/// Claude Code itself.
public struct ClaudeUsageProvider: UsageProvider {
    public let id = ClaudeUsageParser.providerID
    public let displayName = "Claude"

    private let credentials: ClaudeCredentialReading
    private let client: UsageHTTPClient
    private let installation: ClaudeInstallationProbing
    private let now: @Sendable () -> Date
    private let log = Log(category: "claude")

    public init(
        credentials: ClaudeCredentialReading = KeychainClaudeCredentialReader(),
        client: UsageHTTPClient = AnthropicUsageClient(),
        installation: ClaudeInstallationProbing = ClaudeInstallationProbe(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.client = client
        self.installation = installation
        self.now = now
    }

    public func fetchUsage() async -> ProviderState {
        let credential: ClaudeCredential
        do {
            credential = try credentials.readCredential()
        } catch CredentialError.notFound {
            // No credential at all: distinguish "Claude Code isn't here" from
            // "Claude Code is here but signed out", because the fix differs.
            return installation.isInstalled() ? .needsAuthentication : .notInstalled
        } catch CredentialError.accessDenied {
            return .failed("keychain access denied")
        } catch {
            return .failed("credential unreadable")
        }

        // Claude Code owns token refresh. We only read, so an expired token is
        // reported, never renewed.
        if credential.isExpired(now: now()) {
            log.info("claude access token expired")
            return .needsAuthentication
        }

        let outcome = await client.fetchUsage(accessToken: credential.accessToken)

        switch outcome {
        case .success(let data):
            do {
                let snapshot = try ClaudeUsageParser.parse(data: data, fetchedAt: now())
                return .ready(snapshot)
            } catch {
                return .failed("unexpected usage format")
            }
        case .unauthorized:
            return .needsAuthentication
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .offline:
            return .offline
        case .httpError(let code):
            return .failed("HTTP \(code)")
        case .transportError:
            return .failed("network error")
        }
    }

    public func diagnostics() async -> [DiagnosticEntry] {
        var entries: [DiagnosticEntry] = []
        entries.append(.init(label: "Claude Code", value: installation.isInstalled() ? "installed" : "not found"))

        do {
            let credential = try credentials.readCredential()
            entries.append(.init(label: "Claude credential", value: "found"))
            if let expiry = credential.expiresAt {
                let valid = !credential.isExpired(now: now())
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                entries.append(.init(
                    label: "Claude token",
                    value: valid
                        ? "valid (expires \(formatter.localizedString(for: expiry, relativeTo: now())))"
                        : "expired"
                ))
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

        entries.append(.init(label: "Usage endpoint", value: AnthropicUsageClient.endpoint.host ?? "unknown"))
        entries.append(.init(label: "Endpoint status", value: "undocumented / experimental"))
        return entries
    }
}

// MARK: - Installation probe

public protocol ClaudeInstallationProbing: Sendable {
    func isInstalled() -> Bool
    func executablePath() -> String?
}

/// Looks for the Claude Code CLI in its known install locations. Does not execute
/// it — presence is all we need, and running it would be both slow and invasive.
public struct ClaudeInstallationProbe: ClaudeInstallationProbing {
    private let candidates: [String]

    public init(candidates: [String]? = nil) {
        if let candidates {
            self.candidates = candidates
        } else {
            let home = NSHomeDirectory()
            self.candidates = [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        }
    }

    public func executablePath() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func isInstalled() -> Bool { executablePath() != nil }
}
