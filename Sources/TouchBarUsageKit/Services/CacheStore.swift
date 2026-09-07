import Foundation

/// Persists only normalized `UsageSnapshot` values. `UsageSnapshot` has no field
/// that can hold a credential, so "the cache contains no secrets" is a property
/// of the type, not of care taken at the call site.
public protocol SnapshotCaching: Sendable {
    func load(providerID: String) -> UsageSnapshot?
    func save(_ snapshot: UsageSnapshot)
    func clear(providerID: String)
}

public final class CacheStore: SnapshotCaching, @unchecked Sendable {
    private let directory: URL
    private let log = Log(category: "cache")
    private let lock = NSLock()

    public init(directory: URL? = nil, bundleIdentifier: String = "com.gabrielanyog.touchbarusage") {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func url(for providerID: String) -> URL {
        // Provider IDs are developer-defined, but keep the filename tame anyway.
        let safe = providerID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("usage-\(safe).json")
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load(providerID: String) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(for: providerID)) else { return nil }
        do {
            return try CacheStore.decoder.decode(UsageSnapshot.self, from: data)
        } catch {
            // A corrupt or older-format cache is not worth surfacing to the user.
            log.debug("cache decode failed", ["provider": providerID])
            return nil
        }
    }

    public func save(_ snapshot: UsageSnapshot) {
        lock.lock(); defer { lock.unlock() }
        do {
            let data = try CacheStore.encoder.encode(snapshot)
            try data.write(to: url(for: snapshot.providerID), options: .atomic)
        } catch {
            log.debug("cache write failed", ["provider": snapshot.providerID])
        }
    }

    public func clear(providerID: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: providerID))
    }
}

/// Test double.
public final class InMemoryCache: SnapshotCaching, @unchecked Sendable {
    private var storage: [String: UsageSnapshot] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(providerID: String) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }; return storage[providerID]
    }
    public func save(_ snapshot: UsageSnapshot) {
        lock.lock(); defer { lock.unlock() }; storage[snapshot.providerID] = snapshot
    }
    public func clear(providerID: String) {
        lock.lock(); defer { lock.unlock() }; storage[providerID] = nil
    }
}
