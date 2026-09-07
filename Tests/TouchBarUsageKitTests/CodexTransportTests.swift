import XCTest
@testable import TouchBarUsageKit

/// Framing and message-decoding tests. These cover the parts that break in
/// practice — a message split across reads, several in one chunk, a malformed
/// line — without spawning a child process.
final class JSONRPCFramerTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testSingleCompleteLine() {
        var framer = JSONRPCFramer()
        let lines = framer.append(data("{\"a\":1}\n"))
        XCTAssertEqual(lines.count, 1)
    }

    /// A message arriving in pieces must not be delivered until it is complete.
    func testPartialReadsAreBuffered() {
        var framer = JSONRPCFramer()
        XCTAssertTrue(framer.append(data("{\"jsonrpc\":\"2.0\",")).isEmpty)
        XCTAssertTrue(framer.append(data("\"id\":1,\"result\":")).isEmpty)

        let lines = framer.append(data("{\"ok\":true}}\n"))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(JSONRPCFramer.decode(lines[0])?.id, 1)
    }

    func testMultipleMessagesInOneChunk() {
        var framer = JSONRPCFramer()
        let lines = framer.append(data(
            "{\"id\":1,\"result\":{}}\n{\"id\":2,\"result\":{}}\n{\"method\":\"x\"}\n"))
        XCTAssertEqual(lines.count, 3)
    }

    func testTrailingPartialMessageIsHeldBack() {
        var framer = JSONRPCFramer()
        let lines = framer.append(data("{\"id\":1,\"result\":{}}\n{\"id\":2,"))
        XCTAssertEqual(lines.count, 1)

        let rest = framer.append(data("\"result\":{}}\n"))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(JSONRPCFramer.decode(rest[0])?.id, 2)
    }

    func testBlankLinesAreIgnored() {
        var framer = JSONRPCFramer()
        XCTAssertEqual(framer.append(data("\n\n{\"id\":1,\"result\":{}}\n\n")).count, 1)
    }

    func testDecodeResponse() throws {
        let message = try XCTUnwrap(JSONRPCFramer.decode(
            data("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"rateLimits\":{}}}")))
        XCTAssertEqual(message.id, 7)
        XCTAssertTrue(message.isResponse)
        XCTAssertFalse(message.isNotification)
        XCTAssertNotNil(message.result)
        XCTAssertNil(message.errorMessage)
    }

    func testDecodeNotificationCarriesParams() throws {
        let message = try XCTUnwrap(JSONRPCFramer.decode(
            data("{\"jsonrpc\":\"2.0\",\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{}}}")))
        XCTAssertNil(message.id)
        XCTAssertEqual(message.method, "account/rateLimits/updated")
        XCTAssertTrue(message.isNotification)
        XCTAssertNotNil(message.result, "notification params are surfaced to the handler")
    }

    func testDecodeError() throws {
        let message = try XCTUnwrap(JSONRPCFramer.decode(
            data("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32000,\"message\":\"not logged in\"}}")))
        XCTAssertEqual(message.errorMessage, "not logged in")
    }

    /// A malformed line is skipped, not fatal — one bad message must not kill a
    /// long-lived connection.
    func testMalformedLinesDecodeToNil() {
        XCTAssertNil(JSONRPCFramer.decode(data("not json")))
        XCTAssertNil(JSONRPCFramer.decode(data("[]")))
        XCTAssertNil(JSONRPCFramer.decode(data("{\"jsonrpc\":\"2.0\"}")), "no id and no method")
        XCTAssertNil(JSONRPCFramer.decode(Data()))
    }

    func testEncodeRequestAndNotification() throws {
        let request = try XCTUnwrap(JSONRPCFramer.encode(
            id: 5, method: "account/rateLimits/read", params: [:]))
        XCTAssertEqual(request.last, UInt8(ascii: "\n"), "messages are newline delimited")

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 5)
        XCTAssertEqual(object["method"] as? String, "account/rateLimits/read")
        XCTAssertNil(object["params"], "empty params are omitted")

        let notification = try XCTUnwrap(JSONRPCFramer.encode(
            id: nil, method: "initialized", params: [:]))
        let notificationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: notification.dropLast()) as? [String: Any])
        XCTAssertNil(notificationObject["id"], "notifications carry no id")
    }

    /// An unbounded line from a wedged peer must not grow memory without limit.
    func testOversizedBufferIsDropped() {
        var framer = JSONRPCFramer()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
        for _ in 0..<10 { _ = framer.append(chunk) }
        XCTAssertTrue(framer.append(data("\n")).isEmpty, "runaway buffer was discarded")
    }
}

/// Client-level behaviour that does not need a live server.
final class CodexAppServerClientTests: XCTestCase {

    /// The monitor must never call anything that spends credits or emails a user.
    func testOnlyReadOnlyMethodsAreAllowed() {
        XCTAssertEqual(Set(CodexAppServerClient.allowedMethods),
                       ["initialize", "initialized", "account/rateLimits/read"])
        for forbidden in ["account/rateLimitResetCredit/consume",
                          "account/sendAddCreditsNudgeEmail",
                          "account/logout", "thread/start"] {
            XCTAssertFalse(CodexAppServerClient.allowedMethods.contains(forbidden),
                           "\(forbidden) must never be sent")
        }
    }

    func testLoggedOutDetection() {
        for message in ["Not logged in", "user is UNAUTHENTICATED", "auth required",
                        "no account configured", "Unauthorized"] {
            XCTAssertTrue(CodexAppServerClient.looksLikeLoggedOut(message), message)
        }
        for message in ["connection reset", "internal server error", "timeout"] {
            XCTAssertFalse(CodexAppServerClient.looksLikeLoggedOut(message), message)
        }
    }

    /// Server error text may quote account details; only a short generic summary
    /// may reach a log or the diagnostics window.
    func testErrorSanitisationTruncatesAndTakesFirstLine() {
        let message = "failed for user@example.com\nstack trace line\nanother line"
        let sanitised = CodexAppServerClient.sanitize(message)
        XCTAssertFalse(sanitised.contains("\n"))
        XCTAssertLessThanOrEqual(sanitised.count, 80)

        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(CodexAppServerClient.sanitize(long).count, 80)
    }
}

/// Executable discovery.
final class CodexExecutableResolverTests: XCTestCase {

    func testOverrideWins() {
        let resolver = CodexExecutableResolver(environment: [
            CodexExecutableResolver.overrideEnvironmentKey: "/tmp/custom/codex",
        ])
        XCTAssertEqual(resolver.candidates().first, "/tmp/custom/codex")
    }

    func testSearchesPathThenStandardLocations() {
        let resolver = CodexExecutableResolver(environment: ["PATH": "/a:/b"])
        let candidates = resolver.candidates()
        XCTAssertTrue(candidates.contains("/a/codex"))
        XCTAssertTrue(candidates.contains("/b/codex"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/codex"), "Apple silicon Homebrew")
        XCTAssertTrue(candidates.contains("/usr/local/bin/codex"), "Intel Homebrew")
    }

    /// No single machine-specific path may be assumed.
    func testConsidersSeveralDistinctLocations() {
        let candidates = CodexExecutableResolver(environment: [:]).candidates()
        XCTAssertGreaterThan(Set(candidates).count, 3)
    }

    func testMissingExecutableResolvesToNil() {
        XCTAssertNil(StubCodexExecutableResolver(path: nil).executablePath())
    }
}
