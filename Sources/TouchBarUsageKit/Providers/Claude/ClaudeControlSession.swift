import Foundation
import Darwin

/// Polling occurs only during a bounded, short-lived probe, never at app idle.
final class ClaudeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

public struct ClaudeControlSession: ClaudeControlRunning {
    public static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                  "--verbose", "--no-session-persistence"] + ClaudePTYSession.noToolArguments
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 12) { self.timeout = timeout }

    public func usage(executable: String, directory: String) async throws -> Data {
        let cancellation = ClaudeCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        try drive(executable: executable, directory: directory, cancellation: cancellation)
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private func drive(executable: String, directory: String, cancellation: ClaudeCancellation) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ClaudeChildEnvironment.sanitized()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClaudeControlError.launchFailed }
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        defer {
            try? input.fileHandleForWriting.close()
            ClaudeProcessCleanup.stop(process)
            try? output.fileHandleForReading.close()
        }
        var framer = JSONRPCFramer()
        for subtype in ["initialize", "get_usage"] {
            if cancellation.cancelled { throw ClaudeControlError.cancelled }
            let id = UUID().uuidString
            do { try input.fileHandleForWriting.write(contentsOf: ClaudeControlProtocol.request(subtype, id: id)) }
            catch { throw ClaudeControlError.childExited }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var answer: Data?
            while answer == nil {
                if cancellation.cancelled { throw ClaudeControlError.cancelled }
                if ProcessInfo.processInfo.systemUptime >= deadline { throw ClaudeControlError.timedOut }
                var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&fd, 1, 100)
                if result < 0 { if errno == EINTR { continue }; throw ClaudeControlError.childExited }
                if result == 0 { if !process.isRunning { throw ClaudeControlError.childExited }; continue }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(fd.fd, &bytes, bytes.count)
                guard count > 0 else { throw ClaudeControlError.childExited }
                for line in framer.append(Data(bytes.prefix(count))) {
                    if let payload = try ClaudeControlProtocol.response(line, id: id) { answer = payload }
                }
            }
            if subtype == "get_usage" { return answer! }
        }
        throw ClaudeControlError.malformed
    }
}

enum ClaudeProcessCleanup {
    static func stop(_ process: Process) {
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
