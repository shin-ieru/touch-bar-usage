import Foundation

/// A newline-delimited JSON-RPC 2.0 message.
public struct JSONRPCMessage: Equatable, Sendable {
    public let id: Int?
    public let method: String?
    public let result: Data?
    public let errorMessage: String?

    public init(id: Int?, method: String?, result: Data?, errorMessage: String?) {
        self.id = id
        self.method = method
        self.result = result
        self.errorMessage = errorMessage
    }

    public var isResponse: Bool { id != nil && method == nil }
    public var isNotification: Bool { id == nil && method != nil }
}

/// Splits a byte stream into complete JSON-RPC messages.
///
/// Pulled out of the process plumbing so the fiddly part — partial reads, several
/// messages arriving in one chunk, a message split across chunks — is unit tested
/// without spawning anything.
public struct JSONRPCFramer {
    private var buffer = Data()
    /// Set once a line exceeds the cap: everything up to the next newline is a
    /// fragment of that abandoned line and must be thrown away, not delivered as
    /// though it were a complete message.
    private var discardingOversizedLine = false
    /// Guards against a wedged peer streaming an unbounded line.
    public static let maximumLineBytes = 8 * 1024 * 1024

    public init() {}

    /// Appends a chunk and returns every complete line it now contains.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]

            if discardingOversizedLine {
                // That newline ends the abandoned line; resume normally.
                discardingOversizedLine = false
                continue
            }
            if !line.isEmpty { lines.append(Data(line)) }
        }

        if buffer.count > Self.maximumLineBytes {
            buffer.removeAll()
            discardingOversizedLine = true
        }
        return lines
    }

    /// Parses one line. Returns nil for anything that is not a usable message,
    /// so a malformed line is skipped rather than killing the connection.
    public static func decode(_ line: Data) -> JSONRPCMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        let id = (object["id"] as? Int) ?? (object["id"] as? NSNumber)?.intValue
        let method = object["method"] as? String

        var errorMessage: String?
        if let error = object["error"] as? [String: Any] {
            errorMessage = (error["message"] as? String) ?? "JSON-RPC error"
        }

        var result: Data?
        if let value = object["result"] {
            result = try? JSONSerialization.data(withJSONObject: value)
        } else if let params = object["params"], method != nil {
            result = try? JSONSerialization.data(withJSONObject: params)
        }

        guard id != nil || method != nil else { return nil }
        return JSONRPCMessage(id: id, method: method, result: result, errorMessage: errorMessage)
    }

    public static func encode(id: Int?, method: String, params: [String: Any]) -> Data? {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { object["id"] = id }
        if !params.isEmpty { object["params"] = params }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

public enum TransportError: Error, Equatable {
    case notRunning
    case launchFailed
    case timedOut
    case childExited
    case rpc(String)
}

/// Owns the Codex App Server child process and speaks JSON-RPC to it over stdio.
///
/// One long-lived process is kept rather than spawning per refresh: startup costs
/// hundreds of milliseconds, and the server pushes
/// `account/rateLimits/updated` notifications that only a persistent connection
/// can receive.
public actor CodexJSONRPCTransport {

    private let executablePath: String
    private let arguments: [String]
    private let log = Log(category: "codex-rpc")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var framer = JSONRPCFramer()

    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONRPCMessage, Error>] = [:]
    private var notificationHandler: (@Sendable (String, Data?) -> Void)?

    public init(executablePath: String, arguments: [String] = ["app-server"]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func setNotificationHandler(_ handler: @escaping @Sendable (String, Data?) -> Void) {
        notificationHandler = handler
    }

    // MARK: - Lifecycle

    public func start() throws {
        if isRunning { return }
        stop()   // clear any dead remnants

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await self?.ingest(chunk) }
        }
        // Drain stderr so a chatty server cannot fill the pipe and block, but
        // never log its contents: it may echo account details.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            log.warning("codex app server failed to launch")
            throw TransportError.launchFailed
        }

        self.process = process
        self.stdinPipe = stdin
        self.framer = JSONRPCFramer()
        log.info("codex app server started")
    }

    /// Terminates the child and fails every in-flight request. Must leave no
    /// orphan process behind.
    public func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        framer = JSONRPCFramer()
        failAllPending(with: .childExited)
    }

    private func handleTermination() {
        log.warning("codex app server exited")
        process = nil
        stdinPipe = nil
        failAllPending(with: .childExited)
    }

    private func failAllPending(with error: TransportError) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Messaging

    private func ingest(_ chunk: Data) {
        for line in framer.append(chunk) {
            guard let message = JSONRPCFramer.decode(line) else {
                log.debug("skipped unparseable rpc line")
                continue
            }
            if let id = message.id, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(returning: message)
            } else if message.isNotification, let method = message.method {
                notificationHandler?(method, message.result)
            }
        }
    }

    public func notify(method: String, params: [String: Any] = [:]) throws {
        guard let handle = stdinPipe?.fileHandleForWriting, isRunning else {
            throw TransportError.notRunning
        }
        guard let data = JSONRPCFramer.encode(id: nil, method: method, params: params) else { return }
        handle.write(data)
    }

    /// Sends a request and awaits its matching response.
    ///
    /// Responses are matched by id, so an interleaved notification or an
    /// out-of-order response cannot be mistaken for this call's answer.
    public func request(method: String,
                        params: [String: Any] = [:],
                        timeout: TimeInterval = 10) async throws -> Data? {
        guard let handle = stdinPipe?.fileHandleForWriting, isRunning else {
            throw TransportError.notRunning
        }
        let id = nextRequestID
        nextRequestID += 1

        guard let data = JSONRPCFramer.encode(id: id, method: method, params: params) else {
            throw TransportError.rpc("could not encode request")
        }

        // The timeout races the response; whichever lands first wins, and the
        // pending entry is cleared either way so ids are never leaked.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timeOut(id: id)
        }
        defer { timeoutTask.cancel() }

        let message: JSONRPCMessage = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            handle.write(data)
        }

        if let error = message.errorMessage {
            throw TransportError.rpc(error)
        }
        return message.result
    }

    private func timeOut(id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        log.warning("codex request timed out")
        continuation.resume(throwing: TransportError.timedOut)
    }
}
