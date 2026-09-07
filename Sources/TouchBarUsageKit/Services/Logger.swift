import Foundation
import os

/// Tiny logging wrapper. The point of it existing at all (rather than `print`)
/// is `redact` — every structured value passes through key-based redaction so a
/// credential cannot reach the log by accident.
public struct Log: Sendable {
    public enum Level: String, Sendable { case debug, info, warning, error }

    /// Substrings that mark a key as secret-bearing. Matched case-insensitively.
    static let sensitiveKeyMarkers = [
        "token", "secret", "authorization", "auth_header", "credential",
        "password", "passwd", "apikey", "api_key", "bearer", "cookie",
        "session", "signature", "private",
    ]

    public static let redactedPlaceholder = "<redacted>"

    private let subsystem: String
    private let category: String
    private let logger: os.Logger
    /// Set by the app for the diagnostics ring buffer.
    public static let recentEntries = LogRingBuffer(capacity: 200)

    public init(subsystem: String = "com.gabrielanyog.touchbarusage", category: String) {
        self.subsystem = subsystem
        self.category = category
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String, _ metadata: [String: String] = [:]) {
        emit(.debug, message, metadata)
    }
    public func info(_ message: String, _ metadata: [String: String] = [:]) {
        emit(.info, message, metadata)
    }
    public func warning(_ message: String, _ metadata: [String: String] = [:]) {
        emit(.warning, message, metadata)
    }
    public func error(_ message: String, _ metadata: [String: String] = [:]) {
        emit(.error, message, metadata)
    }

    private func emit(_ level: Level, _ message: String, _ metadata: [String: String]) {
        let line = Log.format(message: message, metadata: metadata)
        Log.recentEntries.append("[\(category)] \(line)")
        switch level {
        case .debug:   logger.debug("\(line, privacy: .public)")
        case .info:    logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error:   logger.error("\(line, privacy: .public)")
        }
    }

    /// Builds the final log line with all metadata redacted.
    public static func format(message: String, metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return message }
        let pairs = metadata.keys.sorted().map { key in
            "\(key)=\(redact(key: key, value: metadata[key] ?? ""))"
        }
        return "\(message) {\(pairs.joined(separator: " "))}"
    }

    /// Returns the placeholder when the *key* looks secret-bearing, and also
    /// when the *value* looks like a known token shape regardless of key.
    public static func redact(key: String, value: String) -> String {
        let lowered = key.lowercased()
        if sensitiveKeyMarkers.contains(where: { lowered.contains($0) }) {
            return redactedPlaceholder
        }
        if valueLooksSecret(value) { return redactedPlaceholder }
        return value
    }

    /// Defence in depth: catch token-shaped values even under an innocent key.
    public static func valueLooksSecret(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let prefixes = ["sk-", "sk-ant-", "bearer ", "oat01", "ort01", "eyj"]
        if prefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        if lowered.contains("sk-ant-") { return true }
        if lowered.contains("\"accesstoken\"") || lowered.contains("\"refreshtoken\"") { return true }
        return false
    }
}

/// Fixed-size in-memory buffer backing the diagnostics window. Never persisted.
public final class LogRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: [String] = []
    private let lock = NSLock()

    public init(capacity: Int) { self.capacity = capacity }

    public func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
