import Foundation

/// Normalized provider state. The Touch Bar renderer switches on this and never
/// sees an HTTP status, a URLError, or anything credential-shaped.
public enum ProviderState: Equatable, Sendable {
    case loading
    case ready(UsageSnapshot)
    /// A snapshot we still believe is roughly right, but which we could not refresh.
    case stale(UsageSnapshot, reason: String?)
    case notInstalled
    /// Credential missing or expired. The user must re-authenticate in Claude Code
    /// itself — this app never refreshes tokens.
    case needsAuthentication
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case unsupported(String)
    case failed(String)

    /// The snapshot to draw, if any. `stale` still has drawable numbers.
    public var snapshot: UsageSnapshot? {
        switch self {
        case .ready(let s):      return s
        case .stale(let s, _):   return s
        default:                 return nil
        }
    }

    public var isTerminalFailure: Bool {
        switch self {
        case .notInstalled, .needsAuthentication, .unsupported, .failed: return true
        default: return false
        }
    }

    /// Short, non-sensitive label for logs and diagnostics.
    public var diagnosticLabel: String {
        switch self {
        case .loading:            return "loading"
        case .ready:              return "ready"
        case .stale(_, let r):    return "stale(\(r ?? "unknown"))"
        case .notInstalled:       return "notInstalled"
        case .needsAuthentication:return "needsAuthentication"
        case .rateLimited:        return "rateLimited"
        case .offline:            return "offline"
        case .unsupported(let r): return "unsupported(\(r))"
        case .failed(let r):      return "failed(\(r))"
        }
    }
}
