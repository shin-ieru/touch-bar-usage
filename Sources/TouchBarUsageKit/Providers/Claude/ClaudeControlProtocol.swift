import Foundation

public enum ClaudeControlError: Error, Equatable {
    case unsupported, malformed, timedOut, childExited, launchFailed, cancelled, unavailable
}

/// Experimental Claude stream-json control protocol, not JSON-RPC.
public enum ClaudeControlProtocol {
    public static func request(_ subtype: String, id: String) -> Data {
        var request: [String: Any] = ["subtype": subtype]
        // Verified in 2.1.273: avoid scanning local session history for attribution.
        if subtype == "get_usage" { request["skip_behaviors"] = true }
        var data = try! JSONSerialization.data(withJSONObject: [
            "type": "control_request", "request_id": id, "request": request
        ])
        data.append(10)
        return data
    }

    public static func response(_ line: Data, id: String) throws -> Data? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ClaudeControlError.malformed
        }
        guard event["type"] as? String == "control_response",
              let response = event["response"] as? [String: Any],
              response["request_id"] as? String == id else { return nil }
        if response["subtype"] as? String == "error" {
            let message = (response["error"] as? String ?? "").lowercased()
            if message.contains("unsupported control request subtype") || message.contains("unknown method") {
                throw ClaudeControlError.unsupported
            }
            throw ClaudeControlError.unavailable
        }
        guard response["subtype"] as? String == "success",
              let payload = response["response"] as? [String: Any] else {
            throw ClaudeControlError.malformed
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// SDK 0.3.211 specifies utilization in percent (0–100), including values
    /// below one. Never infer a fractional scale from the magnitude alone.
    public static func snapshot(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["rate_limits_available"] as? Bool != false,
              let limits = root["rate_limits"] as? [String: Any] else {
            throw ClaudeControlError.unavailable
        }
        var buckets: [String: Any] = [:]
        for key in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] {
            if let value = limits[key] { buckets[key] = value }
        }
        var windows: [UsageWindow] = []
        if let normalized = try? ClaudeUsageParser.parse(
            data: JSONSerialization.data(withJSONObject: buckets), fetchedAt: fetchedAt) {
            windows = normalized.windows
        }
        for (index, bucket) in (limits["model_scoped"] as? [[String: Any]] ?? []).enumerated() {
            guard let percent = ClaudeUsageParser.number(in: bucket, keys: ["utilization"]) else { continue }
            windows.append(UsageWindow(id: "model_\(index)", label: "M", longLabel: "Model \(index + 1)",
                                       usedPercent: percent,
                                       resetAt: ClaudeUsageParser.date(in: bucket, keys: ["resets_at"]),
                                       duration: 7 * 86400, category: .modelSpecific))
        }
        guard !windows.isEmpty else { throw ClaudeControlError.malformed }
        return UsageSnapshot(providerID: "claude", windows: windows, fetchedAt: fetchedAt)
    }
}

public protocol ClaudeControlRunning: Sendable {
    func usage(executable: String, directory: String) async throws -> Data
}

/// Version-scoped negative capability cache. Transient errors are retried on the
/// next normal refresh; only an explicit unsupported response disables a method.
public actor ClaudeCLIUsageClient: ClaudeUsageProbing {
    private let resolver: ClaudeInstallationProbing
    private let runner: CommandRunning
    private let transport: ClaudeControlRunning
    private let directory: URL
    private var version: String?
    private var unsupportedVersion: String?
    public private(set) var support = "unknown"
    public var currentVersion: String { version ?? "unknown" }

    public init(resolver: ClaudeInstallationProbing = ClaudeInstallationProbe(),
                runner: CommandRunning = ProcessCommandRunner(),
                transport: ClaudeControlRunning = ClaudeControlSession(),
                directory: URL = ClaudeUsageProbe.defaultProbeDirectory()) {
        self.resolver = resolver; self.runner = runner; self.transport = transport; self.directory = directory
    }

    public func fetchUsage(fetchedAt: Date) async throws -> UsageSnapshot? {
        guard let executable = resolver.executablePath() else { return nil }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = await runner.run(executable: executable, arguments: ["--version"],
                                      workingDirectory: directory.path, timeout: 5)
        let detected = result.flatMap { $0.status == 0 ? Self.safeVersion($0.output) : nil }
        if version != detected { support = "unknown" }
        version = detected
        if let version, unsupportedVersion == version { support = "no"; return nil }
        do {
            let data = try await transport.usage(executable: executable, directory: directory.path)
            support = "yes"
            return try ClaudeControlProtocol.snapshot(data, fetchedAt: fetchedAt)
        } catch ClaudeControlError.unsupported {
            unsupportedVersion = version
            support = "no"
            return nil
        }
    }

    static func safeVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
