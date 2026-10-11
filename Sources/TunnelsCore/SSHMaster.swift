import Foundation
import CryptoKit

public enum SSHError: Error, LocalizedError, Equatable {
    case masterExited(String)
    case timeout
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .masterExited(let text): return SSHErrorText.humanize(text)
        case .timeout: return "Timed out waiting for the connection"
        case .commandFailed(let text): return SSHErrorText.humanize(text)
        }
    }
}

/// Turns ssh's stderr into one short line for the UI.
public enum SSHErrorText {
    /// Two or three words for a menu row, from a `humanize` result.
    public static func short(_ reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("no usable key") { return "No key in agent" }
        if lower.contains("unknown host") { return "Unknown host" }
        if lower.contains("port in use") { return "Port in use" }
        if lower.contains("unreachable") { return "Unreachable" }
        if lower.contains("timed out") { return "Timed out" }
        if lower.contains("host key") { return "Host key failed" }
        if lower.contains("refused the forward") { return "Remote refused" }
        if lower.contains("connection is gone") { return "Disconnected" }
        if lower.contains("exited with status") { return "ssh exited" }
        let words = reason.split(separator: " ")
        return words.count <= 3 ? reason : words.prefix(3).joined(separator: " ") + "…"
    }

    public static func humanize(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("permission denied") {
            return "No usable key in the agent. Run ssh-add."
        }
        if lower.contains("could not resolve hostname") {
            return "Unknown host"
        }
        if lower.contains("address already in use") || lower.contains("port forwarding failed") {
            return "Local port in use"
        }
        if lower.contains("connection refused") || lower.contains("no route to host") {
            return "Host unreachable"
        }
        if lower.contains("connection timed out") || lower.contains("operation timed out") {
            return "Connection timed out"
        }
        if lower.contains("host key verification failed") {
            return "Host key verification failed"
        }
        if lower.contains("remote port forwarding failed") || lower.contains("forwarding failed") {
            return "Remote end refused the forward"
        }
        if lower.contains("control socket") && lower.contains("no such file") {
            return "Connection is gone"
        }
        if text.isEmpty { return "ssh failed" }
        // Last non-empty line, without the "ssh: " prefix.
        let last = text.split(separator: "\n").last.map(String.init) ?? text
        let cleaned = last.replacingOccurrences(of: "ssh: ", with: "")
        return cleaned.isEmpty ? "ssh failed" : cleaned
    }
}

/// One ControlMaster connection to one Host alias. Forwards are added and
/// cancelled on this connection without reconnecting.
public actor SSHMaster {
    public let alias: String
    public let socketPath: String
    private let runner: any ProcessRunning
    private let sshPath: String
    private var handle: (any ProcessHandle)?
    private var exitCode: Int32?
    private var recentOutput: [String] = []
    private let onExit: @Sendable (Int32, String) -> Void
    private let onOutput: (@Sendable (String) -> Void)?

    public init(
        alias: String,
        socketDirectory: URL,
        runner: any ProcessRunning,
        sshPath: String = "/usr/bin/ssh",
        onOutput: (@Sendable (String) -> Void)? = nil,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) {
        self.alias = alias
        self.socketPath = SSHMaster.socketPath(for: alias, in: socketDirectory)
        self.runner = runner
        self.sshPath = sshPath
        self.onOutput = onOutput
        self.onExit = onExit
    }

    /// Unix socket paths are limited to 104 bytes, so the alias is hashed.
    public static func socketPath(for alias: String, in directory: URL) -> String {
        let digest = SHA256.hash(data: Data(alias.utf8))
        let short = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        return directory.appendingPathComponent(String(short)).path
    }

    public var isRunning: Bool { handle?.isRunning ?? false }
    public var lastOutput: String { recentOutput.joined(separator: "\n") }

    /// Development aid: TUNNELS_SSH_CONFIG=/path makes every ssh call use that
    /// config file (-F) instead of ~/.ssh/config. Unset in normal use.
    public static var configArguments: [String] {
        if let path = ProcessInfo.processInfo.environment["TUNNELS_SSH_CONFIG"], !path.isEmpty {
            return ["-F", path]
        }
        return []
    }

    public static let masterOptions: [String] = [
        "-o", "ControlPersist=no",
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",
    ]

    /// Launch the master and wait until `-O check` answers or the process dies.
    public func start(timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.3) async throws {
        if isRunning { return }
        exitCode = nil
        recentOutput = []

        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A stale socket from a previous run would make ssh refuse to become master.
        try? FileManager.default.removeItem(atPath: socketPath)

        let arguments = ["-N", "-M", "-S", socketPath] + SSHMaster.configArguments + SSHMaster.masterOptions + [alias]
        let launched = try runner.launch(
            sshPath,
            arguments: arguments,
            onOutput: { [weak self] line in
                guard let self else { return }
                Task { await self.record(line) }
            },
            onExit: { [weak self] code in
                guard let self else { return }
                Task { await self.handleExit(code) }
            }
        )
        handle = launched

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let code = exitCode {
                throw SSHError.masterExited(lastOutput.isEmpty ? "ssh exited with status \(code)" : lastOutput)
            }
            if await check() { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                launched.terminate()
                throw error
            }
        }
        launched.terminate()
        throw SSHError.timeout
    }

    public func addForward(_ spec: ForwardSpec) async throws {
        try await control(["-O", "forward", "-L", spec.sshArgument])
    }

    public func cancelForward(_ spec: ForwardSpec) async throws {
        try await control(["-O", "cancel", "-L", spec.sshArgument])
    }

    /// Run a command on the machine over the existing connection.
    public func run(_ command: String) async throws -> String {
        let result = try await runner.run(sshPath, arguments: ["-S", socketPath] + SSHMaster.configArguments + ["-o", "BatchMode=yes", alias, "--", command], timeout: 15)
        guard result.succeeded else {
            throw SSHError.commandFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }
        return result.stdout
    }

    public func check() async -> Bool {
        guard let result = try? await runner.run(sshPath, arguments: ["-S", socketPath] + SSHMaster.configArguments + ["-O", "check", alias], timeout: 10) else {
            return false
        }
        return result.succeeded
    }

    /// Ask the master to exit, then make sure it is gone.
    public func stop() async {
        _ = try? await runner.run(sshPath, arguments: ["-S", socketPath] + SSHMaster.configArguments + ["-O", "exit", alias], timeout: 5)
        if let handle, handle.isRunning {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if handle.isRunning { handle.terminate() }
        }
        handle = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Synchronous `-O exit`, for app termination where no async work can run.
    /// Waits at most two seconds, then gives up; the master dies with the app anyway.
    nonisolated public func requestExitNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = ["-S", socketPath] + SSHMaster.configArguments + ["-O", "exit", alias]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func control(_ extra: [String]) async throws {
        let result = try await runner.run(sshPath, arguments: ["-S", socketPath] + SSHMaster.configArguments + extra + [alias], timeout: 15)
        if !result.succeeded {
            let text = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SSHError.commandFailed(text.isEmpty ? "ssh exited with status \(result.exitCode)" : text)
        }
    }

    private func record(_ line: String) {
        recentOutput.append(line)
        if recentOutput.count > 50 { recentOutput.removeFirst(recentOutput.count - 50) }
        onOutput?(line)
    }

    private func handleExit(_ code: Int32) {
        exitCode = code
        handle = nil
        record("[master process ended, status \(code)]")
        try? FileManager.default.removeItem(atPath: socketPath)
        onExit(code, lastOutput)
    }
}
