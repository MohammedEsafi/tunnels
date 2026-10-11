import Foundation

@testable import TunnelsCore

/// Scripted stand-in for ssh. Records every call and lets tests decide the
/// outcome of control commands and simulate the master exiting.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    /// Calls whose result has been handed back, in order; a gated call joins once released.
    private var finished: [Call] = []
    private(set) var launches: [FakeHandle] = []

    /// Decide the result of a `run` call; return nil to fall back to the
    /// defaults: `-O check` succeeds while a master is running, `-O exit`
    /// ends that master, everything else succeeds.
    var script: (([String]) -> ProcessResult?)?
    /// Awaited before every `run` call; lets a test hold a control command
    /// open while something else happens on the controller.
    var gate: (([String]) async -> Void)?
    /// When false the launched master "fails to connect" (check never succeeds).
    var masterConnects = true
    /// If set, the master exits with this code and output right after launch.
    var masterExitsImmediately: (code: Int32, output: String)?

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let call = Call(executable: executable, arguments: arguments)
        let (script, gate, running, connects) = record(call)
        if let gate { await gate(arguments) }
        defer { lock.lock(); finished.append(call); lock.unlock() }
        if let script, let result = script(arguments) { return result }
        if arguments.contains("check") {
            return ProcessResult(exitCode: running && connects ? 0 : 255, stderr: running ? "" : "No ControlPath specified")
        }
        if arguments.contains("exit"), let socket = FakeRunner.socket(in: arguments) {
            runningMasters.first { $0.socketPath == socket }?.simulateExit(code: 0)
        }
        return ProcessResult(exitCode: 0)
    }

    /// Calls containing `fragment` that have returned to the caller.
    func completed(containing fragment: String) -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return finished.filter { $0.arguments.contains(fragment) }
    }

    private func record(_ call: Call) -> ((([String]) -> ProcessResult?)?, (([String]) async -> Void)?, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
        return (script, gate, launches.contains { $0.isRunning }, masterConnects)
    }

    /// The control socket path an ssh invocation names after `-S`.
    static func socket(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-S"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func launch(
        _ executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ProcessHandle {
        let handle = FakeHandle(socketPath: FakeRunner.socket(in: arguments), onExit: onExit)
        lock.lock()
        calls.append(Call(executable: executable, arguments: arguments))
        launches.append(handle)
        let immediate = masterExitsImmediately
        lock.unlock()
        if let immediate {
            onOutput(immediate.output)
            handle.simulateExit(code: immediate.code)
        }
        return handle
    }

    var runningMasters: [FakeHandle] {
        lock.lock(); defer { lock.unlock() }
        return launches.filter { $0.isRunning }
    }

    func calls(containing fragment: String) -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.arguments.contains(fragment) }
    }
}

final class FakeHandle: ProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private let onExit: @Sendable (Int32) -> Void
    let socketPath: String?

    init(socketPath: String?, onExit: @escaping @Sendable (Int32) -> Void) {
        self.socketPath = socketPath
        self.onExit = onExit
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func terminate() {
        simulateExit(code: 15)
    }

    func simulateExit(code: Int32) {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        onExit(code)
    }
}
