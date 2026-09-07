import XCTest
@testable import TouchBarUsageKit

/// These tests encode the promises made in SECURITY.md. If one fails, a
/// credential-handling guarantee has been broken.
final class SecurityTests: XCTestCase {

    // MARK: - Logger redaction

    func testRedactsSensitiveKeys() {
        for key in ["token", "accessToken", "access_token", "refresh_token", "secret",
                    "Authorization", "authorization", "credential", "password",
                    "apiKey", "api_key", "bearer", "cookie", "session_id", "signature"] {
            XCTAssertEqual(
                Log.redact(key: key, value: "value-that-must-not-appear"),
                Log.redactedPlaceholder,
                "key '\(key)' must be redacted"
            )
        }
    }

    func testKeepsHarmlessKeys() {
        XCTAssertEqual(Log.redact(key: "provider", value: "claude"), "claude")
        XCTAssertEqual(Log.redact(key: "status", value: "429"), "429")
        XCTAssertEqual(Log.redact(key: "windows", value: "2"), "2")
    }

    /// Defence in depth: a token-shaped value is redacted even under a benign key.
    func testRedactsTokenShapedValuesRegardlessOfKey() {
        let shapes = [
            "sk-ant-oat01-EXAMPLE",
            "sk-ant-ort01-EXAMPLE",
            "Bearer abc123",
            "eyJhbGciOiJIUzI1NiJ9.payload.sig",
            #"{"accessToken":"x"}"#,
        ]
        for value in shapes {
            XCTAssertEqual(
                Log.redact(key: "note", value: value),
                Log.redactedPlaceholder,
                "token-shaped value '\(value.prefix(12))…' must be redacted"
            )
        }
    }

    func testFormattedLogLineNeverContainsSecretValues() {
        let line = Log.format(
            message: "usage refresh failed",
            metadata: ["provider": "claude", "authorization": "Bearer sk-ant-oat01-SECRET", "status": "401"]
        )
        XCTAssertFalse(line.contains("SECRET"))
        XCTAssertFalse(line.contains("sk-ant"))
        XCTAssertTrue(line.contains("provider=claude"))
        XCTAssertTrue(line.contains("status=401"))
    }

    // MARK: - Credential containment

    /// The credential's description is what an accidental interpolation prints.
    func testCredentialDescriptionIsRedacted() {
        let credential = ClaudeCredential(accessToken: "sk-ant-oat01-SECRET", expiresAt: nil)
        XCTAssertFalse("\(credential)".contains("SECRET"))
        XCTAssertFalse(credential.debugDescription.contains("SECRET"))
        XCTAssertTrue("\(credential)".contains("redacted"))
    }

    /// Only accessToken and expiresAt are lifted out of the keychain blob. The
    /// refresh token must not be carried anywhere, even in memory.
    func testKeychainParseIgnoresRefreshTokenAndAccountFields() throws {
        let blob = """
        {"claudeAiOauth":{"accessToken":"access-value","refreshToken":"refresh-value",
        "expiresAt":1788766431839,"refreshTokenExpiresAt":1789125882839,
        "scopes":["user:inference"],"subscriptionType":"pro"},
        "organizationUuid":"00000000-0000-0000-0000-000000000000"}
        """
        let credential = try KeychainClaudeCredentialReader.parse(Data(blob.utf8))
        XCTAssertEqual(credential.accessToken, "access-value")
        XCTAssertNotNil(credential.expiresAt)

        // Reflect over every stored property: nothing else survived the parse.
        let stored = Mirror(reflecting: credential).children.compactMap { $0.value as? String }
        XCTAssertFalse(stored.contains("refresh-value"), "refresh token must never be read")
        XCTAssertFalse(stored.contains("00000000-0000-0000-0000-000000000000"),
                       "account identifiers must never be read")
    }

    func testExpiryIsParsedFromMilliseconds() throws {
        let blob = #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1788766431839}}"#
        let credential = try KeychainClaudeCredentialReader.parse(Data(blob.utf8))
        let expected = Date(timeIntervalSince1970: 1788766431.839)
        XCTAssertEqual(try XCTUnwrap(credential.expiresAt).timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 0.01)
    }

    func testMalformedOrEmptyCredentialBlobsThrow() {
        for blob in [#"{}"#, #"{"claudeAiOauth":{}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#, "not json"] {
            XCTAssertThrowsError(try KeychainClaudeCredentialReader.parse(Data(blob.utf8))) { error in
                XCTAssertEqual(error as? CredentialError, .malformed)
            }
        }
    }

    func testExpiryComparison() {
        let now = Date.testNow
        XCTAssertFalse(ClaudeCredential(accessToken: "a", expiresAt: now.addingTimeInterval(3600)).isExpired(now: now))
        XCTAssertTrue(ClaudeCredential(accessToken: "a", expiresAt: now.addingTimeInterval(-1)).isExpired(now: now))
        XCTAssertTrue(ClaudeCredential(accessToken: "a", expiresAt: now.addingTimeInterval(30)).isExpired(now: now),
                      "leeway treats an imminent expiry as expired")
        XCTAssertFalse(ClaudeCredential(accessToken: "a", expiresAt: nil).isExpired(now: now))
    }

    // MARK: - Nothing credential-shaped can be serialised

    /// The cached model has no field capable of holding a token. Encoding a
    /// snapshot and scanning the JSON proves it structurally.
    func testEncodedSnapshotContainsNoCredentialFields() throws {
        let snapshot = makeSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self).lowercased()

        for forbidden in ["token", "secret", "authorization", "credential",
                          "password", "bearer", "sk-ant", "organizationuuid", "refresh"] {
            XCTAssertFalse(json.contains(forbidden), "cache JSON must not contain '\(forbidden)'")
        }
    }

    func testCacheRoundTripKeepsOnlyNormalizedData() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let cache = CacheStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = makeSnapshot()
        cache.save(snapshot)
        XCTAssertEqual(cache.load(providerID: "claude"), snapshot)

        // Inspect the bytes actually written to disk.
        let file = directory.appendingPathComponent("usage-claude.json")
        let onDisk = String(decoding: try Data(contentsOf: file), as: UTF8.self).lowercased()
        XCTAssertFalse(onDisk.contains("token"))
        XCTAssertFalse(onDisk.contains("sk-ant"))
        XCTAssertTrue(onDisk.contains("usedpercent"))

        cache.clear(providerID: "claude")
        XCTAssertNil(cache.load(providerID: "claude"))
    }

    func testCorruptCacheFileIsIgnoredRatherThanFatal() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("usage-claude.json"))

        XCTAssertNil(CacheStore(directory: directory).load(providerID: "claude"))
    }

    // MARK: - Diagnostics payload

    /// "Copy Diagnostics" must be safe to paste into a public issue.
    func testDiagnosticsContainNoCredentialMaterial() async {
        let provider = ClaudeUsageProvider(
            credentials: StubCredentialReader(token: "sk-ant-oat01-SECRET",
                                              expiresAt: Date.testNow.addingTimeInterval(3600)),
            client: StubHTTPClient(always: .success(Data())),
            installation: StubInstallationProbe(installed: true),
            now: { .testNow }
        )
        let text = await provider.diagnostics()
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")

        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.lowercased().contains("sk-ant"))
        XCTAssertTrue(text.contains("Claude credential: found"), "presence is reported, value is not")
    }

    /// The one remote destination is Anthropic, and it is not configurable.
    func testOnlyNetworkDestinationIsAnthropic() {
        XCTAssertEqual(AnthropicUsageClient.endpoint.host, "api.anthropic.com")
        XCTAssertEqual(AnthropicUsageClient.endpoint.scheme, "https")
    }
}
