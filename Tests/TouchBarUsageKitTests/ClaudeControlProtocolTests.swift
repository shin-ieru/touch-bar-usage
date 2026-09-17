import XCTest
@testable import TouchBarUsageKit

final class ClaudeControlProtocolTests: XCTestCase {
    func testRequestsContainOnlyControlMessagesAndUniqueIDs() throws {
        for subtype in ["initialize", "get_usage"] {
            let id = UUID().uuidString
            let data = ClaudeControlProtocol.request(subtype, id: id)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(root["type"] as? String, "control_request")
            XCTAssertEqual(root["request_id"] as? String, id)
            XCTAssertEqual((root["request"] as? [String: Any])?["subtype"] as? String, subtype)
            if subtype == "get_usage" {
                XCTAssertEqual((root["request"] as? [String: Any])?["skip_behaviors"] as? Bool, true)
            }
            XCTAssertNil(root["message"])
            XCTAssertEqual(data.last, 10)
        }
    }
    func testPartialMultipleAndInterleavedEvents() throws {
        let text = #"{"type":"system"}"# + "\n" + #"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}"# + "\n" + #"{"type":"control_response","response":{"subtype":"success","request_id":"wanted","response":{"rate_limits":{}}}}"# + "\n"
        for split in 0...text.utf8.count {
            var framer = JSONRPCFramer()
            let data = Data(text.utf8)
            let lines = framer.append(Data(data.prefix(split))) + framer.append(Data(data.dropFirst(split)))
            let matches = try lines.compactMap { try ClaudeControlProtocol.response($0, id: "wanted") }
            XCTAssertEqual(matches.count, 1)
        }
    }
    func testUnsupportedAndMalformedResponses() {
        let error = Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"a","error":"Unsupported control request subtype: get_usage"}}"#.utf8)
        XCTAssertThrowsError(try ClaudeControlProtocol.response(error, id: "a")) { XCTAssertEqual($0 as? ClaudeControlError, .unsupported) }
        XCTAssertThrowsError(try ClaudeControlProtocol.response(Data("no".utf8), id: "a"))
        let malformed = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"a"}}"#.utf8)
        XCTAssertThrowsError(try ClaudeControlProtocol.response(malformed, id: "a"))
    }
    func testPercentScaleResetAndModelWindows() throws {
        let data = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":0.72,"resets_at":"2026-09-17T08:00:00Z"},"seven_day":{"utilization":72},"seven_day_opus":{"utilization":120},"model_scoped":[{"display_name":"Future model","utilization":-4}]}}"#.utf8)
        let snapshot = try ClaudeControlProtocol.snapshot(data, fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 0.72)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 72)
        XCTAssertNotNil(snapshot.shortWindow?.resetAt)
        XCTAssertEqual(snapshot.windows.count, 4)
        XCTAssertEqual(snapshot.windows.first { $0.id == "seven_day_opus" }?.usedPercent, 100)
        XCTAssertEqual(snapshot.windows.first { $0.id == "model_0" }?.usedPercent, 0)
    }
    func testBooleanUtilizationIsMalformed() {
        XCTAssertThrowsError(try ClaudeControlProtocol.snapshot(
            Data(#"{"rate_limits":{"five_hour":{"utilization":true}}}"#.utf8), fetchedAt: .testNow))
    }
    func testNumericAuthAndContradictoryExitAreUnknown() {
        for (text, status) in [(#"{"loggedIn":1}"#, Int32(0)), (#"{"loggedIn":false}"#, Int32(0)), (#"{"loggedIn":true}"#, Int32(1))] {
            let state = ClaudeAuthProbe.parse(output: text, status: status)
            guard case .unknown = state else { XCTFail("expected unknown"); continue }
        }
    }
    func testRedrawnUsageUsesLatestValues() throws {
        let text = "Current session\n20% used\nCurrent week\n7% used\nCurrent session\n30% used\nCurrent week\n9% used"
        let snapshot = try ClaudeUsageCLIParser.parse(output: text, fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 30)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 9)
    }
    func testTrustPromptRequiresExactProbePath() {
        XCTAssertNil(ClaudePTYSession.setupScreen(in: "Do you trust the files /someone/ClaudeProbe", directory: "/app/ClaudeProbe"))
        XCTAssertNotNil(ClaudePTYSession.setupScreen(in: "Do you trust the files /app/ClaudeProbe", directory: "/app/ClaudeProbe"))
        XCTAssertNil(ClaudePTYSession.setupScreen(in: "Press enter to continue", directory: "/app/ClaudeProbe"))
    }
    func testMissingOptionalWindows() throws {
        let snapshot = try ClaudeControlProtocol.snapshot(Data(#"{"rate_limits":{"five_hour":{"utilization":12}}}"#.utf8), fetchedAt: .testNow)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertNil(snapshot.weeklyWindow)
    }
    func testUnavailableOrMalformedLimitsDoNotBecomeZeroUsage() {
        for text in ["{}", #"{"rate_limits":null}"#, #"{"rate_limits":{}}"#, #"{"rate_limits_available":false,"rate_limits":{}}"#] {
            XCTAssertThrowsError(try ClaudeControlProtocol.snapshot(Data(text.utf8), fetchedAt: .testNow))
        }
    }
    func testCapabilityCacheInvalidatesWhenVersionChanges() async throws {
        let runner = VersionRunner()
        let transport = CountingControl()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ClaudeCLIUsageClient(resolver: StubInstallationProbe(installed: true), runner: runner, transport: transport, directory: dir)
        _ = try await client.fetchUsage(fetchedAt: .testNow)
        _ = try await client.fetchUsage(fetchedAt: .testNow)
        var count = await transport.count
        XCTAssertEqual(count, 1)
        await runner.setVersion("2.2.0")
        _ = try await client.fetchUsage(fetchedAt: .testNow)
        count = await transport.count
        XCTAssertEqual(count, 2)
    }
    func testLaunchFlagsDisableSideEffects() {
        let args = ClaudeControlSession.arguments
        for flag in ["--tools", "--strict-mcp-config", "--setting-sources", "--no-session-persistence", "--no-chrome"] { XCTAssertTrue(args.contains(flag)) }
        XCTAssertTrue(args.contains(#"{"theme":"dark","disableAllHooks":true}"#))
    }
}

actor VersionRunner: CommandRunning {
    var version = "2.1.62"
    func setVersion(_ value: String) { version = value }
    func run(executable: String, arguments: [String], workingDirectory: String?, timeout: TimeInterval) async -> (output: String, status: Int32)? { (version + " (Claude Code)", 0) }
}
actor CountingControl: ClaudeControlRunning {
    var count = 0
    func usage(executable: String, directory: String) async throws -> Data { count += 1; throw ClaudeControlError.unsupported }
}
