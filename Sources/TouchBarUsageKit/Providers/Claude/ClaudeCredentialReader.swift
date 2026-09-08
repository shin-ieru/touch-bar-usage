import Foundation
import Security

/// A short-lived access token plus its stated expiry.
///
/// Deliberately **not** `Codable`, **not** `CustomStringConvertible`-friendly, and
/// never stored in a model that reaches the cache or the UI. It exists only for
/// the duration of one HTTP request. The refresh token is never read into this
/// type at all — Claude Code owns the authentication lifecycle (see SECURITY.md).
public struct ClaudeCredential: Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }   // no expiry stated → assume usable
        return now.addingTimeInterval(leeway) >= expiresAt
    }
}

/// Redacting description, so an accidental interpolation cannot leak the token.
extension ClaudeCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ClaudeCredential(accessToken: <redacted>)" }
    public var debugDescription: String { description }
}

public enum CredentialError: Error, Equatable {
    case notFound
    case accessDenied
    case malformed
}

public protocol ClaudeCredentialReading: Sendable {
    func readCredential() throws -> ClaudeCredential
}

/// Reads the existing Claude Code keychain item. Read-only: this type never
/// writes, updates, or deletes a keychain entry, and never touches the refresh
/// token field even though it is present in the stored JSON.
public struct KeychainClaudeCredentialReader: ClaudeCredentialReading {
    /// The generic-password service name Claude Code stores its OAuth blob under.
    public static let serviceName = "Claude Code-credentials"

    private let service: String
    private let allowInteraction: Bool
    private let log = Log(category: "credential")

    /// `allowInteraction` is false for routine refreshes so a keychain dialog can
    /// never block them. It exists as a parameter only so a future explicit
    /// user-initiated "grant access" action could opt in.
    public init(service: String = KeychainClaudeCredentialReader.serviceName,
                allowInteraction: Bool = false) {
        self.service = service
        self.allowInteraction = allowInteraction
    }

    public func readCredential() throws -> ClaudeCredential {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            // Fail rather than prompt.
            //
            // Without this the call blocks indefinitely inside SecItemCopyMatching
            // while macOS shows a keychain dialog — from a background menu-bar app
            // that is an invisible hang, and on every refresh it would be a
            // recurring interruption. Returning `errSecInteractionNotAllowed`
            // lets the provider fall back to the CLI instead.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialError.malformed }
            defer { /* `data` is released with the autorelease pool; not persisted */ }
            return try Self.parse(data)
        case errSecItemNotFound:
            log.info("claude credential not found")
            throw CredentialError.notFound
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            // The user declined the keychain prompt, or we are not in the item's ACL.
            log.warning("claude credential access denied", ["status": "\(status)"])
            throw CredentialError.accessDenied
        default:
            log.warning("claude credential read failed", ["status": "\(status)"])
            throw CredentialError.accessDenied
        }
    }

    /// Extracts *only* `claudeAiOauth.accessToken` and `claudeAiOauth.expiresAt`.
    /// Every other field in the blob — including `refreshToken` and any account
    /// identifiers — is ignored and never copied out.
    static func parse(_ data: Data) throws -> ClaudeCredential {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw CredentialError.malformed
        }
        // Claude Code stores expiry as milliseconds since the epoch.
        var expiry: Date?
        if let ms = oauth["expiresAt"] as? Double, ms > 0 {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int, ms > 0 {
            expiry = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return ClaudeCredential(accessToken: token, expiresAt: expiry)
    }
}
