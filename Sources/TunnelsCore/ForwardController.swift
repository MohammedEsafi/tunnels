import Foundation
import Observation

/// Owns desired state (what the switches say) and actual state (what ssh
/// reports). Everything the UI shows comes from here.
@Observable
@MainActor
public final class ForwardController {
    public private(set) var forwards: [Forward] = []
    public private(set) var machineStates: [String: MachineState] = [:]
    /// Recent ssh output per machine, newest last, capped.
    public private(set) var logs: [String: [String]] = [:]

    private let runner: any ProcessRunning
    private let socketDirectory: URL
    private var masters: [String: SSHMaster] = [:]
    private var startingMasters: [String: Task<SSHMaster, Error>] = [:]

    /// Set by the reconnector. Receives the alias and ssh's last output.
    public var onMasterDropped: (@MainActor (String, String) -> Void)?

    public init(runner: any ProcessRunning, socketDirectory: URL) {
        self.runner = runner
        self.socketDirectory = socketDirectory
    }

    // MARK: Reading state

    /// Machine aliases in display order.
    public var machines: [String] {
        Array(Set(forwards.map(\.spec.machine)).union(machineStates.keys)).sorted()
    }

    public func forwards(on alias: String) -> [Forward] {
        forwards.filter { $0.spec.machine == alias }
    }

    public func machineState(_ alias: String) -> MachineState {
        machineStates[alias] ?? .disconnected
    }

    public var activeCount: Int { forwards.filter { $0.state == .active }.count }
    public var droppedCount: Int { forwards.filter { $0.state == .dropped }.count }
    public var anyDesired: Bool { forwards.contains { $0.desiredOn } }

    // MARK: Changing the list

    /// Replace favourites, keeping the state of any forward that already exists.
    public func setFavourites(_ specs: [(spec: ForwardSpec, name: String)]) {
        var next: [Forward] = []
        for item in specs {
            if let existing = forwards.first(where: { $0.spec == item.spec }) {
                var kept = existing
                kept.name = item.name
                kept.isFavourite = true
                next.append(kept)
            } else {
                next.append(Forward(spec: item.spec, name: item.name, isFavourite: true))
            }
        }
        // Anything still on stays in the list, now as an ad-hoc forward.
        for existing in forwards where existing.desiredOn {
            if !next.contains(where: { $0.spec == existing.spec }) {
                var adHoc = existing
                adHoc.isFavourite = false
                next.append(adHoc)
            }
        }
        forwards = next
    }

    /// Add a forward typed in the quick-open field and turn it on.
    @discardableResult
    public func addAdHoc(_ spec: ForwardSpec, name: String? = nil) async -> Forward.ID {
        if let existing = forwards.first(where: { $0.spec == spec }) {
            await setForward(id: existing.id, on: true)
            return existing.id
        }
        let forward = Forward(spec: spec, name: name ?? spec.remoteHostLabel, isFavourite: false)
        forwards.append(forward)
        await setForward(id: forward.id, on: true)
        return forward.id
    }

    public func remove(id: Forward.ID) async {
        await setForward(id: id, on: false)
        forwards.removeAll { $0.id == id && !$0.isFavourite }
    }

    // MARK: Switches

    public func setForward(id: Forward.ID, on: Bool) async {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        forwards[index].desiredOn = on
        let forward = forwards[index]
        if on {
            await open(forward)
        } else {
            await close(forward)
        }
    }

    /// The master switch: every forward on the machine on or off.
    public func setMachine(alias: String, on: Bool) async {
        if on {
            for index in forwards.indices where forwards[index].spec.machine == alias {
                forwards[index].desiredOn = true
            }
            await retry(alias: alias)
        } else {
            for forward in forwards(on: alias) {
                await setForward(id: forward.id, on: false)
            }
            if let master = masters[alias] {
                await master.stop()
                masters[alias] = nil
            }
            machineStates[alias] = .disconnected
        }
    }

    /// Re-apply every desired forward on a machine, starting the master if needed.
    public func retry(alias: String) async {
        let wanted = forwards(on: alias).filter { $0.desiredOn }
        guard !wanted.isEmpty else {
            machineStates[alias] = .disconnected
            return
        }
        for forward in wanted { update(forward.id) { $0.state = .pending } }
        do {
            _ = try await ensureMaster(alias)
        } catch {
            let reason = (error as? SSHError)?.errorDescription ?? error.localizedDescription
            machineStates[alias] = .failed(reason: reason)
            for forward in wanted { update(forward.id) { $0.state = .dropped } }
            return
        }
        for forward in wanted {
            await open(forward)
        }
    }

    public func closeAll() async {
        for forward in forwards where forward.desiredOn {
            await setForward(id: forward.id, on: false)
        }
    }

    public func reopenAll() async {
        for alias in machines where forwards(on: alias).contains(where: { $0.desiredOn && $0.state != .active }) {
            await retry(alias: alias)
        }
    }

    /// Ask every connected master whether it still answers. A silent one is
    /// treated like an exit so the reconnector takes over.
    public func healthCheck() async {
        for (alias, master) in masters where machineState(alias) == .connected {
            if await !master.check() {
                await master.stop()
                await masterDidExit(alias: alias, code: -1, output: "health check failed")
            }
        }
    }

    /// Reconnector bookkeeping.
    public func markDropped(alias: String, attempt: Int) {
        machineStates[alias] = .dropped(attempt: attempt)
        for forward in forwards(on: alias) where forward.desiredOn && forward.state != .active {
            update(forward.id) { $0.state = .dropped }
        }
    }

    public func markFailed(alias: String, reason: String) {
        machineStates[alias] = .failed(reason: reason)
    }

    /// Called on quit. Desired state is left untouched so it can be persisted.
    public func shutdown() async {
        // Forget the masters first so their exit callbacks are not taken for drops.
        let current = masters
        masters = [:]
        for (alias, master) in current {
            await master.stop()
            machineStates[alias] = .disconnected
        }
        for index in forwards.indices where forwards[index].state != .off {
            forwards[index].state = .off
        }
    }

    /// Synchronous variant for `applicationShouldTerminate`, where AppKit does
    /// not run main-actor tasks. Idempotent with `shutdown()`.
    public func shutdownNow() {
        let current = masters
        masters = [:]
        for (alias, master) in current {
            master.requestExitNow()
            machineStates[alias] = .disconnected
        }
        for index in forwards.indices where forwards[index].state != .off {
            forwards[index].state = .off
        }
    }

    public func clearLog(alias: String) {
        logs[alias] = []
    }

    // MARK: Internals

    private func open(_ forward: Forward) async {
        update(forward.id) { $0.state = .pending }
        let master: SSHMaster
        do {
            master = try await ensureMaster(forward.spec.machine)
        } catch {
            // Master failed: every desired forward on the machine is affected.
            let reason = (error as? SSHError)?.errorDescription ?? error.localizedDescription
            machineStates[forward.spec.machine] = .failed(reason: reason)
            for f in forwards(on: forward.spec.machine) where f.desiredOn {
                update(f.id) { $0.state = .dropped }
            }
            return
        }
        guard forwards.first(where: { $0.id == forward.id })?.desiredOn == true else { return }
        do {
            try await master.addForward(forward.spec)
            update(forward.id) { $0.state = .active }
        } catch {
            let reason = (error as? SSHError)?.errorDescription ?? error.localizedDescription
            update(forward.id) { $0.state = .error(reason) }
        }
    }

    private func close(_ forward: Forward) async {
        let alias = forward.spec.machine
        if let master = masters[alias], forward.state == .active {
            try? await master.cancelForward(forward.spec)
        }
        update(forward.id) { $0.state = .off }
        // Last forward off: drop the master too.
        if let master = masters[alias], !forwards(on: alias).contains(where: { $0.desiredOn }) {
            await master.stop()
            masters[alias] = nil
            machineStates[alias] = .disconnected
        } else if masters[alias] == nil, !forwards(on: alias).contains(where: { $0.desiredOn }) {
            machineStates[alias] = .disconnected
        }
    }

    private func ensureMaster(_ alias: String) async throws -> SSHMaster {
        if let master = masters[alias], await master.isRunning {
            return master
        }
        if let starting = startingMasters[alias] {
            return try await starting.value
        }
        machineStates[alias] = .connecting
        appendLog(alias, "— connecting —")
        let task = Task<SSHMaster, Error> { [runner, socketDirectory] in
            let master = SSHMaster(
                alias: alias,
                socketDirectory: socketDirectory,
                runner: runner,
                onOutput: { line in
                    Task { @MainActor in self.appendLog(alias, line) }
                },
                onExit: { code, output in
                    Task { @MainActor in
                        await self.masterDidExit(alias: alias, code: code, output: output)
                    }
                }
            )
            try await master.start()
            return master
        }
        startingMasters[alias] = task
        defer { startingMasters[alias] = nil }
        do {
            let master = try await task.value
            masters[alias] = master
            machineStates[alias] = .connected
            appendLog(alias, "— connected —")
            return master
        } catch {
            masters[alias] = nil
            appendLog(alias, "— failed: \((error as? SSHError)?.errorDescription ?? error.localizedDescription) —")
            throw error
        }
    }

    private func masterDidExit(alias: String, code: Int32, output: String) async {
        // Ignore exits we asked for.
        guard masters[alias] != nil else { return }
        masters[alias] = nil
        appendLog(alias, "— master exited (\(code)) —")
        let wanted = forwards(on: alias).filter { $0.desiredOn }
        if wanted.isEmpty {
            machineStates[alias] = .disconnected
            return
        }
        machineStates[alias] = .dropped(attempt: 1)
        for forward in wanted {
            update(forward.id) { $0.state = .dropped }
        }
        onMasterDropped?(alias, output)
    }

    private func appendLog(_ alias: String, _ line: String) {
        var lines = logs[alias] ?? []
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        logs[alias] = lines
    }

    private func update(_ id: Forward.ID, _ change: (inout Forward) -> Void) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        change(&forwards[index])
    }
}

extension ForwardSpec {
    /// Display name for an ad-hoc forward: the remote port, or host:port when
    /// the remote host is not localhost.
    var remoteHostLabel: String {
        remoteHost == "localhost" || remoteHost == "127.0.0.1" ? "\(remotePort)" : "\(remoteHost):\(remotePort)"
    }
}
