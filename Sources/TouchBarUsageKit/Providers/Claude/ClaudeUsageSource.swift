import Foundation

/// Where a Claude usage figure came from.
///
/// Tracked so Diagnostics can say which path served the numbers, and so a
/// silently degraded fallback is visible rather than invisible.
public enum ClaudeUsageSource: String, Equatable, Sendable {
    /// The read-only OAuth usage endpoint. The fast path, and the default.
    case oauth
    /// Claude Code's own `/usage` command, run in an isolated session.
    case cli
    /// A previously fetched snapshot, kept visible while both live paths fail.
    case staleCache

    public var diagnosticDescription: String {
        switch self {
        case .oauth:      return "OAuth"
        case .cli:        return "CLI fallback"
        case .staleCache: return "stale cache"
        }
    }
}

/// What Claude Code itself says about being signed in.
///
/// This is the **only** thing allowed to conclude that the user is logged out.
/// An OAuth or keychain failure says nothing about the account — it says only
/// that Touch Bar Usage could not use the fast path.
public enum ClaudeAuthState: Equatable, Sendable {
    case loggedIn
    case loggedOut
    /// The probe could not answer — not installed, timed out, unparseable.
    /// Deliberately distinct from `loggedOut`: uncertainty must never be
    /// rendered as "Sign in".
    case unknown(String)

    public var isConfirmedLoggedOut: Bool { self == .loggedOut }
}

/// Why the OAuth fast path was not used, for diagnostics. Sanitized by
/// construction — these are fixed strings, never server or credential text.
public enum ClaudeOAuthFailure: String, Equatable, Sendable {
    case credentialNotFound
    case credentialUnreadable
    case keychainAccessDenied
    case tokenRejected            // HTTP 401/403
    case httpError
    case offline
    case unexpectedFormat
    case rateLimited

    public var diagnosticDescription: String {
        switch self {
        case .credentialNotFound:   return "credential not found"
        case .credentialUnreadable: return "credential unreadable"
        case .keychainAccessDenied: return "keychain access denied"
        case .tokenRejected:        return "token rejected"
        case .httpError:            return "usage endpoint error"
        case .offline:              return "offline"
        case .unexpectedFormat:     return "unexpected usage format"
        case .rateLimited:          return "rate limited"
        }
    }
}
