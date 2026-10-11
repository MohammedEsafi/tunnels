import Foundation
import Observation

/// Owns desired state (what the switches say) and actual state (what ssh
/// reports), one master connection per machine.
@Observable
@MainActor
public final class ForwardController {
    public internal(set) var forwards: [Forward] = []
    public internal(set) var machineStates: [String: MachineState] = [:]
    /// Recent ssh output per machine, newest last, capped.
    public internal(set) var logs: [String: [String]] = [:]

    let runner: any ProcessRunning
    let options: SSHOptions
    var masters: [String: SSHMaster] = [:]
    var startingMasters: [String: Task<SSHMaster, Error>] = [:]

    /// Fired when a master exits on its own, with the alias and ssh's last
    /// output. The reconnector listens.
    public var onMasterDropped: (@MainActor (String, String) -> Void)?

    /// Machines in all-ports mode that are switched on.
    public internal(set) var autoHosts: Set<String> = []
    /// Ports not to forward, per auto host.
    public internal(set) var autoExcluded: [String: Set<Int>] = [:]
    /// What the last scan of each auto host found (minus exclusions), kept
    /// after the host is switched off so "Pinned only" can freeze it.
    public internal(set) var lastDiscovered: [String: Set<Int>] = [:]
    /// Per-machine offset, assigned the first time one of its discovered
    /// ports is taken locally: 10000 for the first machine, 20000 next.
    public internal(set) var offsets: [String: Int] = [:]
    /// Fired once when a machine gets its offset.
    public var onOffsetAssigned: (@MainActor (String, Int) -> Void)?
    /// A pinned forward was moved to another local port because its own was
    /// taken: old spec, new spec. The app rewrites the favourites file.
    public var onForwardMoved: (@MainActor (ForwardSpec, ForwardSpec) -> Void)?
    /// How often an auto host is scanned.
    public var discoveryInterval: TimeInterval = 5
    /// Whether a local port is already served by something on this Mac.
    /// Replaceable so tests do not depend on the machine they run on.
    public var localPortProbe: (Int) -> Bool = LocalPorts.isTaken
    var discoveryLoops: [String: Task<Void, Never>] = [:]
    var scanning: Set<String> = []

    public init(runner: any ProcessRunning, options: SSHOptions) {
        self.runner = runner
        self.options = options
    }

    // MARK: Reading state

    /// Machine aliases in display order: those with forwards, auto hosts that
    /// are on, plus any that still have a live or failing master.
    public var machines: [String] {
        let live = machineStates.filter { $0.value != .disconnected }.map(\.key)
        return Array(Set(forwards.map(\.spec.machine)).union(live).union(autoHosts)).sorted()
    }

    public func forwards(on alias: String) -> [Forward] {
        forwards.filter { $0.spec.machine == alias }
    }

    public func machineState(_ alias: String) -> MachineState {
        machineStates[alias] ?? .disconnected
    }

    /// Anything to close: a forward that is wanted on, or a machine being watched.
    public var anyDesired: Bool { forwards.contains { $0.desiredOn } || !autoHosts.isEmpty }

    // MARK: Changing the list

    /// Replace favourites, keeping the state of any forward that already exists.
    public func setFavourites(_ favourites: [Favourite]) {
        var next: [Forward] = []
        for item in favourites {
            if let existing = forwards.first(where: { $0.spec == item.spec }) {
                var kept = existing
                kept.name = item.name
                kept.isFavourite = true
                kept.isDiscovered = false  // pinned now; discovery leaves it alone
                kept.movedByApp = item.movedByApp
                next.append(kept)
            } else {
                next.append(Forward(spec: item.spec, name: item.name, isFavourite: true, movedByApp: item.movedByApp))
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

    /// Machines whose next opening should try plain numbers again: set by a
    /// manual switch-on, consumed by `open`.
    var tryPlainOnce: Set<String> = []

    /// The master switch: every forward on the machine on or off. Switching
    /// on by hand means "start from the best numbers available": the offset
    /// is dropped and forwards the app had moved try their plain number.
    public func setMachine(alias: String, on: Bool) async {
        if !on, autoHosts.contains(alias) {
            await disableAutoHost(alias)
        }
        if on {
            offsets[alias] = nil
            tryPlainOnce.insert(alias)
            for index in forwards.indices where forwards[index].spec.machine == alias {
                forwards[index].desiredOn = true
            }
            await retry(alias: alias)
            tryPlainOnce.remove(alias)
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
        guard !wanted.isEmpty || autoHosts.contains(alias) else {
            machineStates[alias] = .disconnected
            return
        }
        for forward in wanted { update(forward.id) { $0.state = .pending } }
        do {
            _ = try await ensureMaster(alias)
        } catch {
            machineFailed(alias, error)
            return
        }
        for forward in wanted {
            await open(forward)
        }
    }

    /// Turn every machine off: forwards, all-ports watching and the masters.
    public func closeAll() async {
        for alias in machines {
            await setMachine(alias: alias, on: false)
        }
    }

    public func reopenAll() async {
        for alias in machines where forwards(on: alias).contains(where: { $0.desiredOn && $0.state != .active }) {
            await retry(alias: alias)
        }
    }

    /// Ask every connected master whether it still answers. A silent one is
    /// treated like an exit so the reconnector takes over. Connected ones
    /// also get their pinned forwards' remote ports probed.
    public func healthCheck() async {
        for (alias, master) in masters where machineState(alias) == .connected {
            if await !master.check() {
                appendLog(alias, "health check: no answer, dropping")
                await master.stop()
                await masterDidExit(alias: alias, code: -1, output: "health check failed")
            } else {
                await probe(alias: alias)
            }
        }
    }

    /// Does anything listen on the remote end of each pinned forward? A
    /// forward with no service behind it is open but useless, so mark it.
    /// Remote hosts other than the machine itself cannot be checked this way.
    public func probe(alias: String) async {
        guard let master = masters[alias] else { return }
        let candidates = forwards(on: alias).filter {
            !$0.isDiscovered && ($0.state == .active || $0.state == .noService)
                && $0.spec.isLoopbackRemote
        }
        guard !candidates.isEmpty, let output = try? await master.run(PortDiscovery.command) else { return }
        let listening = PortDiscovery.listeners(output)
        guard !listening.isEmpty else { return }  // no tool answered; say nothing
        for forward in candidates {
            let has = listening.contains(forward.spec.remotePort)
            update(forward.id) { $0.state = has ? .active : .noService }
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
        for (_, loop) in discoveryLoops { loop.cancel() }
        discoveryLoops = [:]
        for (_, starting) in startingMasters { starting.cancel() }
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
        for (_, loop) in discoveryLoops { loop.cancel() }
        discoveryLoops = [:]
        for (_, starting) in startingMasters { starting.cancel() }
        let current = masters
        masters = [:]
        for alias in current.keys { machineStates[alias] = .disconnected }
        // Every master is asked to exit at once: logout and shutdown give the
        // process only a few seconds before SIGKILL, not a few per machine.
        let group = DispatchGroup()
        for master in current.values {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                master.requestExitNow()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 2.5)
        for index in forwards.indices where forwards[index].state != .off {
            forwards[index].state = .off
        }
    }

    // MARK: Internals

    func open(_ forward: Forward) async {
        // A forward the app moved earlier: on a manual switch-on, see whether
        // its own number is free again before using the moved one.
        if forward.movedByApp, !forward.isDiscovered, tryPlainOnce.contains(forward.spec.machine),
            forward.spec.localPort != forward.spec.remotePort, !isLocalPortTaken(forward.spec.remotePort)
        {
            await tryPlain(forward)
            return
        }
        update(forward.id) { $0.state = .pending }
        let master: SSHMaster
        do {
            master = try await ensureMaster(forward.spec.machine)
        } catch {
            machineFailed(forward.spec.machine, error)
            return
        }
        guard forwards.first(where: { $0.id == forward.id })?.desiredOn == true else { return }
        do {
            try await master.addForward(forward.spec)
            // Switched off while ssh was adding it: take it straight down again.
            guard let added = forwards.first(where: { $0.id == forward.id }), added.desiredOn else {
                await close(forward.withState(.active))
                return
            }
            update(forward.id) { $0.state = .active }
            appendLog(forward.spec.machine, "forward \(forward.spec.sshArgument) open")
            if !forward.isDiscovered { await probe(alias: forward.spec.machine) }
        } catch {
            let reason = error.localizedDescription
            update(forward.id) { $0.state = .error(reason) }
            appendLog(forward.spec.machine, "forward \(forward.spec.sshArgument) failed: \(reason)")
            if reason == "Local port in use", !forward.isDiscovered, forward.spec.localPort == forward.spec.remotePort {
                await movePinned(forward)
            }
        }
    }

    func close(_ forward: Forward) async {
        let alias = forward.spec.machine
        // A forward with nothing listening behind it is still bound locally.
        if let master = masters[alias], forward.state == .active || forward.state == .noService {
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

    func ensureMaster(_ alias: String) async throws -> SSHMaster {
        if let master = masters[alias], await master.isRunning {
            return master
        }
        if let starting = startingMasters[alias] {
            return try await starting.value
        }
        machineStates[alias] = .connecting
        appendLog(alias, "connecting")
        let task = Task<SSHMaster, Error> { [runner, options] in
            let master = SSHMaster(
                alias: alias,
                options: options,
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
            // Everything that wanted this connection may have been switched
            // off while it was starting, or the app may be shutting down; do
            // not keep an idle master around.
            guard self.isWanted(alias), !Task.isCancelled else {
                await master.stop()
                throw CancellationError()
            }
            return master
        }
        startingMasters[alias] = task
        defer { startingMasters[alias] = nil }
        do {
            let master = try await task.value
            masters[alias] = master
            machineStates[alias] = .connected
            appendLog(alias, "connected")
            return master
        } catch {
            masters[alias] = nil
            if !(error is CancellationError) { appendLog(alias, "failed: \(error.localizedDescription)") }
            throw error
        }
    }

    /// A machine is wanted while a forward on it is switched on or it is watched.
    public func isWanted(_ alias: String) -> Bool {
        autoHosts.contains(alias) || forwards(on: alias).contains { $0.desiredOn }
    }

    /// The master could not be had: a cancelled start is not a failure, anything
    /// else is, and every desired forward on the machine shows it.
    func machineFailed(_ alias: String, _ error: Error) {
        if error is CancellationError {
            machineStates[alias] = .disconnected
            return
        }
        machineStates[alias] = .failed(reason: error.localizedDescription)
        for forward in forwards(on: alias) where forward.desiredOn {
            update(forward.id) { $0.state = .dropped }
        }
    }

    func masterDidExit(alias: String, code: Int32, output: String) async {
        // Ignore exits we asked for.
        guard masters[alias] != nil else {
            appendLog(alias, "(an old connection exited with \(code); ignored)")
            return
        }
        masters[alias] = nil
        appendLog(alias, "connection exited (\(code)) last output: \(output.suffix(160))")
        let wanted = forwards(on: alias).filter { $0.desiredOn }
        if wanted.isEmpty && !autoHosts.contains(alias) {
            machineStates[alias] = .disconnected
            return
        }
        machineStates[alias] = .dropped(attempt: 1)
        for forward in wanted {
            update(forward.id) { $0.state = .dropped }
        }
        onMasterDropped?(alias, output)
    }

    private static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func appendLog(_ alias: String, _ line: String) {
        var lines = logs[alias] ?? []
        lines.append(ForwardController.logTime.string(from: Date()) + "  " + line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        logs[alias] = lines
    }

    func update(_ id: Forward.ID, _ change: (inout Forward) -> Void) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        change(&forwards[index])
    }
}
