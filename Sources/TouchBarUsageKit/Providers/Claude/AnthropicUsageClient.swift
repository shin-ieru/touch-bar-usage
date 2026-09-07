import Foundation

/// Outcome of one read-only usage request. Carries no headers and no raw body
/// beyond the bytes the parser needs.
public enum UsageFetchOutcome {
    case success(Data)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case httpError(Int)
    case transportError
}

public protocol UsageHTTPClient: Sendable {
    func fetchUsage(accessToken: String) async -> UsageFetchOutcome
}

/// Performs the single read-only GET this app makes.
///
/// The endpoint is **undocumented / experimental** — it is what Claude Code's own
/// OAuth session uses, not a published public API. See docs/security-model.md.
/// No other host is ever contacted.
public struct AnthropicUsageClient: UsageHTTPClient {
    /// The only remote destination in this application.
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Required for OAuth-scoped endpoints. Observed, not documented.
    static let betaHeader = "oauth-2025-04-20"

    private let session: URLSession
    private let log = Log(category: "network")

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral   // no on-disk cache
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    public func fetchUsage(accessToken: String) async -> UsageFetchOutcome {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        // The token appears here and nowhere else: not in the URL, not in a
        // query item, not in a process argument, not in any log line.
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transportError }

            switch http.statusCode {
            case 200...299:
                log.debug("usage request ok", ["status": "\(http.statusCode)"])
                return .success(data)
            case 401, 403:
                log.warning("usage request unauthorized", ["status": "\(http.statusCode)"])
                return .unauthorized
            case 429:
                let retry = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
                log.warning("usage request rate limited")
                return .rateLimited(retryAfter: retry)
            default:
                log.warning("usage request failed", ["status": "\(http.statusCode)"])
                return .httpError(http.statusCode)
            }
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return .offline
            default:
                log.warning("usage request transport error", ["code": "\(error.code.rawValue)"])
                return .transportError
            }
        } catch {
            return .transportError
        }
    }
}
