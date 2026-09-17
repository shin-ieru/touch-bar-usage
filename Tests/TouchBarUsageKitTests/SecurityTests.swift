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

}
