import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }

    /// Exit code reported when a `run` call hit its timeout.
    public static let timedOutExitCode: Int32 = 124
}

/// A long-running child process.
public protocol ProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

/// Abstraction over Foundation.Process so the core can be tested without ssh.
public protocol ProcessRunning: Sendable {
    /// Run to completion and collect output. A process still running after
    /// `timeout` seconds is terminated and reported with `timedOutExitCode`.
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult

    /// Launch and return immediately. `onOutput` receives stderr/stdout lines as
    /// they arrive, `onExit` fires once with the exit code.
    func launch(
        _ executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ProcessHandle
}

public extension ProcessRunning {
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, timeout: 20)
    }
}

public final class SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            // Drain pipes concurrently so a chatty child cannot block on a full pipe.
            let outData = DataBox()
            let errData = DataBox()
            let timedOut = FlagBox()
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { outData.append(data) }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { errData.append(data) }
            }

            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outData.append(out.fileHandleForReading.readDataToEndOfFile())
                errData.append(err.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ProcessResult(
                    exitCode: timedOut.isSet ? ProcessResult.timedOutExitCode : proc.terminationStatus,
                    stdout: outData.string,
                    stderr: errData.string
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut.set()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    public func launch(
        _ executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let lineHandler: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    onOutput(String(line))
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = lineHandler
        err.fileHandleForReading.readabilityHandler = lineHandler

        process.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus)
        }

        try process.run()
        return SystemProcessHandle(process: process)
    }
}

final class SystemProcessHandle: ProcessHandle, @unchecked Sendable {
    private let process: Process
    init(process: Process) { self.process = process }
    var isRunning: Bool { process.isRunning }
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// Thread-safe byte accumulator for pipe readers.
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ more: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(more)
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class FlagBox: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
