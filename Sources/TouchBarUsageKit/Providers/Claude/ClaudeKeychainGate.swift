import Foundation

/// Decides whether the keychain fast path is worth attempting.
///
/// ## Why this exists
///
/// Reading Claude Code's credential can make macOS show an "allow access"
/// dialog. That dialog is governed by the keychain item's **ACL**, which matches
/// on code signature — and it is not suppressible by a query flag
/// (`kSecUseAuthenticationUI` covers biometric prompts, not this).
///
/// Two consequences were observed on real hardware:
///
/// - `SecItemCopyMatching` **blocks** for as long as the dialog is on screen. In
///   a background menu-bar app that is an invisible hang with no log output.
/// - If the user dismisses it, the next refresh asks again. At a five-minute
///   cadence that is a dialog every five minutes, forever.
///
/// An ad-hoc signed build makes this worse: the signature changes on every
/// rebuild, so the ACL never matches and the prompt never stops.
///
/// So after the keychain proves unavailable, the fast path is skipped for a
/// while and the CLI fallback is used instead. The user gets their numbers and
/// stops being interrupted; the fast path is retried later in case access was
/// granted in the meantime.
public actor ClaudeKeychainGate {

    /// Long enough that the user is not pestered, short enough that granting
    /// access is picked up in the same session.
    public static let defaultCooldown: TimeInterval = 30 * 60

    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private var blockedUntil: Date?
    private let log = Log(category: "credential")

    public init(cooldown: TimeInterval = ClaudeKeychainGate.defaultCooldown,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.cooldown = cooldown
        self.now = now
    }

    public func shouldAttempt() -> Bool {
        guard let blockedUntil else { return true }
        if now() >= blockedUntil {
            self.blockedUntil = nil
            return true
        }
        return false
    }

    /// Called when the keychain could not be read without interaction, or did not
    /// answer in time.
    public func recordUnavailable() {
        blockedUntil = now().addingTimeInterval(cooldown)
        log.info("keychain fast path paused; using cli fallback",
                 ["minutes": "\(Int(cooldown / 60))"])
    }

    /// Called on a successful read, so a recovered grant takes effect at once.
    public func recordAvailable() {
        blockedUntil = nil
    }

    public var isPaused: Bool { blockedUntil != nil && now() < blockedUntil! }
}

/// Reads a credential without letting a keychain dialog hang the caller.
///
/// `SecItemCopyMatching` blocks while the ACL prompt is displayed, so it is run
/// off the caller's task with a deadline. On timeout the read is abandoned — the
/// dialog remains the user's to answer, but the refresh is not held hostage by it.
public struct TimeLimitedCredentialReader: ClaudeCredentialReading {
    private let underlying: ClaudeCredentialReading
    private let timeout: TimeInterval

    public init(_ underlying: ClaudeCredentialReading, timeout: TimeInterval = 3) {
        self.underlying = underlying
        self.timeout = timeout
    }

    public func readCredential() throws -> ClaudeCredential {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            do { box.set(.success(try underlying.readCredential())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            // Still waiting on a dialog. Treat as unavailable, not as a logout.
            throw CredentialError.accessDenied
        }
        return try box.take()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<ClaudeCredential, Error>?
        func set(_ value: Result<ClaudeCredential, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() throws -> ClaudeCredential {
            lock.lock(); defer { lock.unlock() }
            guard let result else { throw CredentialError.accessDenied }
            return try result.get()
        }
    }
}
