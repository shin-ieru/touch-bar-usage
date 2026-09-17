import XCTest
@testable import TouchBarUsageKit

final class ClaudeProcessTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbu-fake-" + UUID().uuidString)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func testActualProcessHandshakeAndUsage() async throws {
        let url = try script(#"""
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/')
          case "$line" in
            *initialize*) printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id" ;;
            *get_usage*) printf '{"type":"system"}\n'; printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"rate_limits":{"five_hour":{"utilization":42}}}}}\n' "$id" ;;
            *) exit 7 ;;
          esac
        done
        """#)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await ClaudeControlSession(timeout: 8).usage(executable: url.path, directory: NSTemporaryDirectory())
        XCTAssertEqual(try ClaudeControlProtocol.snapshot(data, fetchedAt: .testNow).shortWindow?.usedPercent, 42)
    }
    func testChildExit() async throws {
        let url = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ClaudeControlSession(timeout: 5).usage(executable: url.path, directory: NSTemporaryDirectory())
            XCTFail("expected exit")
        } catch { XCTAssertEqual(error as? ClaudeControlError, .childExited) }
    }
    func testTimeoutKillsUncooperativeChild() async throws {
        let url = try script("trap '' TERM\nwhile IFS= read -r line; do :; done\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        do {
            _ = try await ClaudeControlSession(timeout: 0.15).usage(executable: url.path, directory: NSTemporaryDirectory())
            XCTFail("expected timeout")
        } catch { XCTAssertEqual(error as? ClaudeControlError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testCancellationTerminatesProbe() async throws {
        let url = try script("while IFS= read -r line; do :; done")
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await ClaudeControlSession(timeout: 30).usage(executable: url.path, directory: NSTemporaryDirectory()) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertEqual(error as? ClaudeControlError, .cancelled) }
    }
    func testMissingExecutable() async {
        do {
            _ = try await ClaudeControlSession().usage(executable: "/missing/tbu-claude", directory: NSTemporaryDirectory())
            XCTFail("expected launch failure")
        } catch { XCTAssertEqual(error as? ClaudeControlError, .launchFailed) }
    }
    func testAuthTimeoutIsUnknownEvenAfterClosingStdout() async throws {
        let url = try script("exec 1>&-\ntrap '' TERM\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await ProcessCommandRunner().run(executable: url.path, arguments: [], workingDirectory: NSTemporaryDirectory(), timeout: 0.1)
        XCTAssertNil(result)
    }
    func testPTYUsageRoundTrip() async throws {
        let url = try script("printf '? for shortcuts\\n'\nIFS= read -r command\nprintf 'Current session\\n42%% used\\nResets 6pm\\nCurrent week\\n12%% used\\nResets Tue\\n'\nwhile IFS= read -r line; do :; done")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await ClaudePTYSession(readyTimeout: 5, commandTimeout: 5)
            .runSlashCommand("/usage", executable: url.path, workingDirectory: NSTemporaryDirectory())
        guard case .output(let text) = result else { return XCTFail("expected usage output") }
        let snapshot = try ClaudeUsageCLIParser.parse(output: text, fetchedAt: .testNow)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 42)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 12)
    }
    func testPTYAbortsOnGlobalOnboarding() async throws {
        let url = try script("printf 'Choose the text style\\n'\nwhile IFS= read -r line; do :; done")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await ClaudePTYSession(readyTimeout: 2)
            .runSlashCommand("/usage", executable: url.path, workingDirectory: NSTemporaryDirectory())
        XCTAssertEqual(result, .timedOut)
    }
    func testUnknownPromptIsNeverAnswered() async throws {
        let url = try script("printf 'Unknown consent screen\\n'\nIFS= read -r line\nprintf 'Current session 100%% used\\n'")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await ClaudePTYSession(readyTimeout: 2)
            .runSlashCommand("/usage", executable: url.path, workingDirectory: NSTemporaryDirectory())
        XCTAssertEqual(result, .timedOut)
    }
    func testPTYRejectsModelPrompts() async {
        let result = await ClaudePTYSession().runSlashCommand("hello", executable: "/missing", workingDirectory: NSTemporaryDirectory())
        XCTAssertEqual(result, .launchFailed)
    }
}
