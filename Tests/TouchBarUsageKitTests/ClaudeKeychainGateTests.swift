import XCTest
@testable import TouchBarUsageKit

/// The keychain fast path must never become a recurring interruption.
///
/// Observed on hardware: reading Claude Code's credential can raise a macOS ACL
/// dialog; `SecItemCopyMatching` blocks while it is on screen, and dismissing it
/// only means the next refresh asks again. At a five-minute cadence that is a
/// dialog every five minutes.
final class ClaudeKeychainGateTests: XCTestCase {

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date = .testNow
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }

    func testAttemptsByDefault() async {
        let gate = ClaudeKeychainGate()
        let should = await gate.shouldAttempt()
        XCTAssertTrue(should)
    }

    func testPausesAfterUnavailable() async {
        let clock = Clock()
        let gate = ClaudeKeychainGate(cooldown: 1800, now: { clock.now })

        await gate.recordUnavailable()
        var should = await gate.shouldAttempt()
        XCTAssertFalse(should, "a denied prompt must not be retried immediately")

        clock.advance(600)
        should = await gate.shouldAttempt()
        XCTAssertFalse(should, "still inside the cooldown")
    }

    /// The pause is temporary: granting access later must take effect without
    /// restarting the app.
    func testResumesAfterCooldown() async {
        let clock = Clock()
        let gate = ClaudeKeychainGate(cooldown: 1800, now: { clock.now })

        await gate.recordUnavailable()
        clock.advance(1801)
        let should = await gate.shouldAttempt()
        XCTAssertTrue(should)
    }

    func testSuccessClearsThePauseImmediately() async {
        let clock = Clock()
        let gate = ClaudeKeychainGate(cooldown: 1800, now: { clock.now })

        await gate.recordUnavailable()
        await gate.recordAvailable()
        let should = await gate.shouldAttempt()
        XCTAssertTrue(should)
        let paused = await gate.isPaused
        XCTAssertFalse(paused)
    }

    /// A blocked keychain read must not hang the refresh — an invisible hang in a
    /// background menu-bar app is worse than a visible failure.
    func testSlowReadTimesOutAsUnavailable() {
        let reader = TimeLimitedCredentialReader(BlockingCredentialReader(), timeout: 0.2)
        let started = Date()
        XCTAssertThrowsError(try reader.readCredential()) { error in
            XCTAssertEqual(error as? CredentialError, .accessDenied,
                           "a stuck prompt is unavailability, never a logout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "must not wait on the dialog")
    }

    func testFastReadPassesThrough() throws {
        let reader = TimeLimitedCredentialReader(
            StubCredentialReader(token: "test-token-not-a-real-credential",
                                 expiresAt: Date.testNow.addingTimeInterval(3600)),
            timeout: 2)
        let credential = try reader.readCredential()
        XCTAssertEqual(credential.accessToken, "test-token-not-a-real-credential")
    }

    func testUnderlyingErrorsArePreserved() {
        let reader = TimeLimitedCredentialReader(StubCredentialReader(error: .notFound), timeout: 2)
        XCTAssertThrowsError(try reader.readCredential()) {
            XCTAssertEqual($0 as? CredentialError, .notFound)
        }
    }

    /// End to end: a denied keychain must produce usage from the CLI, not a
    /// repeated prompt and not "Sign in".
    func testDeniedKeychainFallsBackWithoutRepeatedPrompting() async {
        let clock = Clock()
        let gate = ClaudeKeychainGate(cooldown: 1800, now: { clock.now })
        let reads = ReadCounter()
        let installation = StubInstallationProbe(installed: true)

        let snapshot = UsageSnapshot(providerID: "claude", windows: [
            UsageWindow(id: "five_hour", label: "5h", usedPercent: 40, category: .short),
        ], fetchedAt: .testNow)

        let provider = ClaudeUsageProvider(
            credentials: CountingCredentialReader(counter: reads),
            client: StubHTTPClient(always: .unauthorized),
            installation: installation,
            authProbe: ClaudeAuthProbe(resolver: installation,
                                       runner: StubCommandRunner(output: #"{"loggedIn": true}"#)),
            usageProbe: StubClaudeUsageProbe(snapshot: snapshot),
            keychainGate: gate,
            now: { .testNow })

        let first = await provider.fetchUsage()
        XCTAssertEqual(first.snapshot?.shortWindow?.usedPercent, 40)
        XCTAssertNotEqual(first, .needsAuthentication)

        // Several more refreshes inside the cooldown must not touch the keychain.
        let readsAfterFirst = reads.value
        for _ in 0..<5 { _ = await provider.fetchUsage() }
        XCTAssertEqual(reads.value, readsAfterFirst,
                       "the keychain must not be re-read while paused")
    }
}

/// Never returns in time — stands in for a read blocked behind an ACL dialog.
private struct BlockingCredentialReader: ClaudeCredentialReading {
    func readCredential() throws -> ClaudeCredential {
        Thread.sleep(forTimeInterval: 5)
        return ClaudeCredential(accessToken: "unused", expiresAt: nil)
    }
}

final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

/// Always denies, and counts how often it was asked.
private struct CountingCredentialReader: ClaudeCredentialReading {
    let counter: ReadCounter
    func readCredential() throws -> ClaudeCredential {
        counter.increment()
        throw CredentialError.accessDenied
    }
}
