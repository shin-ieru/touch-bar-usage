import Foundation

public enum ClaudeUsageSource: String, Equatable, Sendable {
    case controlProtocol, cli, staleCache
    public var diagnosticDescription: String {
        switch self {
        case .controlProtocol: return "Control protocol (experimental)"
        case .cli: return "/usage compatibility fallback"
        case .staleCache: return "stale cache"
        }
    }
}

public enum ClaudeAuthState: Equatable, Sendable {
    case loggedIn, loggedOut, notInstalled
    case unknown(String)
    public var isConfirmedLoggedOut: Bool { self == .loggedOut }
}
