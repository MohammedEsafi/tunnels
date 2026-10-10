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
    private(set) var launches: [FakeHandle] = []

    /// Decide the result of a `run` call. Default: `-O check` succeeds once a
    /// master is running, everything else succeeds.
    var script: (([String]) -> ProcessResult)?
    /// When false the launched master "fails to connect" (check never succeeds).
    var masterConnects = true
    /// If set, the master exits with this code and output right after launch.
    var masterExitsImmediately: (code: Int32, output: String)?

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let (script, running, connects) = record(Call(executable: executable, arguments: arguments))
        if let script { return script(arguments) }
        if arguments.contains("check") {
            return ProcessResult(exitCode: running && connects ? 0 : 255, stderr: running ? "" : "No ControlPath specified")
        }
        return ProcessResult(exitCode: 0)
    }

    private func record(_ call: Call) -> ((([String]) -> ProcessResult)?, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
        return (script, launches.contains { $0.isRunning }, masterConnects)
    }

    func launch(
        _ executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ProcessHandle {
        let handle = FakeHandle(onExit: onExit)
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

    init(onExit: @escaping @Sendable (Int32) -> Void) {
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
