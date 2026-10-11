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

    /// Machines in all-ports mode that are switched on.
    public private(set) var autoHosts: Set<String> = []
    /// Ports not to forward, per auto host.
    public private(set) var autoExcluded: [String: Set<Int>] = [:]
    /// What the last scan of each auto host found (minus exclusions), kept
    /// after the host is switched off so "Pinned only" can freeze it.
    public private(set) var lastDiscovered: [String: Set<Int>] = [:]
    /// Per-machine offset, assigned the first time one of its discovered
    /// ports is taken locally: 10000 for the first machine, 20000 next.
    public private(set) var offsets: [String: Int] = [:]
    /// Fired once when a machine gets its offset.
    public var onOffsetAssigned: (@MainActor (String, Int) -> Void)?
    /// A pinned forward was moved to another local port because its own was
    /// taken: old spec, new spec. The app rewrites the favourites file.
    public var onForwardMoved: (@MainActor (ForwardSpec, ForwardSpec) -> Void)?
    /// How often an auto host is scanned.
    public var discoveryInterval: TimeInterval = 5
    private var discoveryLoops: [String: Task<Void, Never>] = [:]
    private var scanning: Set<String> = []

    public init(runner: any ProcessRunning, socketDirectory: URL) {
        self.runner = runner
        self.socketDirectory = socketDirectory
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

    public var activeCount: Int { forwards.filter { $0.state == .active || $0.state == .noService }.count }
    public var droppedCount: Int { forwards.filter { $0.state == .dropped }.count }
    /// Anything to close: a forward that is wanted on, or a machine being watched.
    public var anyDesired: Bool { forwards.contains { $0.desiredOn } || !autoHosts.isEmpty }

    // MARK: Changing the list

    /// Replace favourites, keeping the state of any forward that already exists.
    public func setFavourites(_ specs: [(spec: ForwardSpec, name: String)]) {
        setFavourites(specs.map { Favourite(name: $0.name, spec: $0.spec) })
    }

    public func setFavourites(_ favourites: [Favourite]) {
        var next: [Forward] = []
        for item in favourites {
            if let existing = forwards.first(where: { $0.spec == item.spec }) {
                var kept = existing
                kept.name = item.name
                kept.isFavourite = true
                kept.isDiscovered = false   // pinned now; discovery leaves it alone
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

    // MARK: All ports

    /// Watch a machine and forward every listener it has, except `excluded`.
    public func enableAutoHost(_ alias: String, excluded: Set<Int> = [], offset: Int? = nil) {
        autoExcluded[alias] = excluded
        if let offset { offsets[alias] = offset }
        guard !autoHosts.contains(alias) else { return }
        autoHosts.insert(alias)
        discoveryLoops[alias] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan(alias)
                let interval = self?.discoveryInterval ?? 5
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stop watching and close the discovered forwards. Pinned ones stay.
    public func disableAutoHost(_ alias: String) async {
        discoveryLoops[alias]?.cancel()
        discoveryLoops[alias] = nil
        autoHosts.remove(alias)
        for forward in forwards(on: alias) where forward.isDiscovered {
            await close(forward)
            forwards.removeAll { $0.id == forward.id }
        }
        if !forwards(on: alias).contains(where: { $0.desiredOn }), let master = masters[alias] {
            await master.stop()
            masters[alias] = nil
            machineStates[alias] = .disconnected
        }
    }

    /// "Not this one": drop a discovered port and keep it dropped. Exclusions
    /// are keyed by the remote port, which is what discovery reports; the local
    /// number may carry an offset.
    public func excludePort(remotePort port: Int, on alias: String) async {
        autoExcluded[alias, default: []].insert(port)
        lastDiscovered[alias]?.remove(port)
        for forward in forwards(on: alias) where forward.isDiscovered && forward.spec.remotePort == port {
            await close(forward)
            forwards.removeAll { $0.id == forward.id }
        }
    }

    public func includePort(_ port: Int, on alias: String) {
        autoExcluded[alias]?.remove(port)
    }

    /// One discovery pass: add forwards for new listeners, drop vanished ones,
    /// retry the ones that failed (a local port may have freed up).
    public func scan(_ alias: String) async {
        guard autoHosts.contains(alias), !scanning.contains(alias) else { return }
        scanning.insert(alias)
        defer { scanning.remove(alias) }
        let master: SSHMaster
        do {
            master = try await ensureMaster(alias)
        } catch {
            machineFailed(alias, error)
            return
        }
        // The host can be switched off during any of the awaits below; a scan
        // that carried on would reopen what the switch just closed.
        guard autoHosts.contains(alias), let output = try? await master.run(PortDiscovery.command), autoHosts.contains(alias) else {
            if autoHosts.contains(alias) { appendLog(alias, "scan: could not list ports") }
            return
        }
        let excluded = autoExcluded[alias] ?? []
        let pinnedRemote = Set(forwards(on: alias).filter {
            !$0.isDiscovered && ($0.spec.remoteHost == "localhost" || $0.spec.remoteHost == "127.0.0.1")
        }.map(\.spec.remotePort))
        let wanted = PortDiscovery.parse(output).subtracting(excluded).subtracting(pinnedRemote)
        lastDiscovered[alias] = wanted
        let current = forwards(on: alias).filter(\.isDiscovered)
        appendLog(alias, "scan: listening \(PortDiscovery.parse(output).sorted()) excluded \(excluded.sorted()) have \(current.map(\.spec.remotePort).sorted())")

        for forward in current where !wanted.contains(forward.spec.remotePort) {
            await close(forward)
            forwards.removeAll { $0.id == forward.id }
        }
        for port in wanted.sorted() where !current.contains(where: { $0.spec.remotePort == port }) {
            guard autoHosts.contains(alias) else { return }
            await openDiscovered(port, on: alias)
        }
        // Enforce the rule every time, whatever history produced: with an
        // offset, no discovered row may sit on a plain number; and a failed
        // row gets another go (its local port may have freed up).
        for forward in forwards(on: alias) where forward.isDiscovered {
            guard autoHosts.contains(alias) else { return }
            let wrongNumber = offsets[alias] != nil && forward.spec.localPort == forward.spec.remotePort
            var failed = false
            if case .error = forward.state { failed = true }
            if wrongNumber || failed {
                await close(forward)
                forwards.removeAll { $0.id == forward.id }
                await openDiscovered(forward.spec.remotePort, on: alias)
            }
        }
    }

    /// Open a discovered port. A machine without an offset tries the plain
    /// number; the first clash gives the machine an offset, after which every
    /// discovered port on it uses that offset, so the mapping never depends
    /// on which machine connected first.
    private func openDiscovered(_ port: Int, on alias: String) async {
        if offsets[alias] == nil {
            let plain = Forward(spec: ForwardSpec(machine: alias, localPort: port), name: String(port), isFavourite: false, isDiscovered: true, desiredOn: true)
            if !isLocalPortTaken(port) {
                forwards.append(plain)
                await open(plain)
                guard case .error(let reason) = forwards.first(where: { $0.id == plain.id })?.state,
                      reason == "Local port in use" else { return }
                forwards.removeAll { $0.id == plain.id }
            }
            let offset = nextOffset()
            offsets[alias] = offset
            appendLog(alias, "local ports taken: using +\(offset) for this machine")
            // Ports already open on plain numbers move too, so the rule is whole.
            for existing in forwards(on: alias) where existing.isDiscovered && existing.spec.localPort == existing.spec.remotePort {
                await close(existing)
                forwards.removeAll { $0.id == existing.id }
                await openMoved(existing.spec.remotePort, on: alias, offset: offset)
            }
            onOffsetAssigned?(alias, offset)
        }
        await openMoved(port, on: alias, offset: offsets[alias]!)
    }

    private func openMoved(_ port: Int, on alias: String, offset: Int) async {
        let moved = Forward(spec: ForwardSpec(machine: alias, localPort: port + offset, remotePort: port), name: String(port), isFavourite: false, isDiscovered: true, desiredOn: true)
        forwards.append(moved)
        await open(moved)
    }

    /// Forget a machine's offset; its next scan tries plain numbers again.
    public func clearOffset(_ alias: String) {
        offsets[alias] = nil
    }

    /// Something of ours already listens there, so do not even try the plain number.
    private func isLocalPortTaken(_ port: Int) -> Bool {
        forwards.contains { $0.spec.localPort == port && ($0.state == .active || $0.state == .noService) }
    }

    private func nextOffset() -> Int {
        var candidate = 10000
        while offsets.values.contains(candidate) { candidate += 10000 }
        return candidate
    }

    /// Machines whose next opening should try plain numbers again: set by a
    /// manual switch-on, consumed by `open`.
    private var tryPlainOnce: Set<String> = []

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
        guard !wanted.isEmpty else {
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
                && ($0.spec.remoteHost == "localhost" || $0.spec.remoteHost == "127.0.0.1")
        }
        guard !candidates.isEmpty, let output = try? await master.run(PortDiscovery.command) else { return }
        let listening = PortDiscovery.listeners(output)
        guard !listening.isEmpty else { return } // no tool answered; say nothing
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
        // A forward the app moved earlier: on a manual switch-on, see whether
        // its own number is free again before using the moved one.
        if forward.movedByApp, !forward.isDiscovered, tryPlainOnce.contains(forward.spec.machine),
           forward.spec.localPort != forward.spec.remotePort, !isLocalPortTaken(forward.spec.remotePort) {
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
            update(forward.id) { $0.state = .active }
            // Switched off while ssh was adding it: take it straight down again.
            guard let added = forwards.first(where: { $0.id == forward.id }), added.desiredOn else {
                await close(forward.withState(.active))
                return
            }
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

    /// Put a moved pinned forward back on its plain number if that binds;
    /// otherwise carry on with the moved number.
    private func tryPlain(_ forward: Forward) async {
        let alias = forward.spec.machine
        let plain = ForwardSpec(machine: alias, localPort: forward.spec.remotePort, remoteHost: forward.spec.remoteHost, remotePort: forward.spec.remotePort)
        guard let master = try? await ensureMaster(alias) else {
            var plainless = forward
            plainless.movedByApp = false
            await open(plainless)
            return
        }
        update(forward.id) { $0.state = .pending }
        if (try? await master.addForward(plain)) != nil {
            // The row may be gone by now; rows are found by id, never by position.
            guard forwards.contains(where: { $0.id == forward.id }) else {
                try? await master.cancelForward(plain)
                return
            }
            update(forward.id) {
                $0.spec = plain
                $0.movedByApp = false
                $0.state = .active
            }
            appendLog(alias, "forward \(forward.spec.sshArgument) back on local \(plain.localPort)")
            onForwardMoved?(forward.spec, plain)
            await probe(alias: alias)
        } else {
            var keep = forward
            keep.movedByApp = false   // so this pass does not loop
            update(forward.id) { $0.movedByApp = false }
            await open(keep)
            update(forward.id) { $0.movedByApp = true }
        }
    }

    /// A pinned forward whose plain number is taken moves to remote + the
    /// machine's offset, assigning one if needed, like a discovered port.
    private func movePinned(_ forward: Forward) async {
        let alias = forward.spec.machine
        let offset: Int
        if let existing = offsets[alias] {
            offset = existing
        } else {
            offset = nextOffset()
            offsets[alias] = offset
            appendLog(alias, "local ports taken: using +\(offset) for this machine")
            onOffsetAssigned?(alias, offset)
        }
        let moved = ForwardSpec(machine: alias, localPort: forward.spec.remotePort + offset, remoteHost: forward.spec.remoteHost, remotePort: forward.spec.remotePort)
        guard !forwards.contains(where: { $0.spec == moved }),
              let index = forwards.firstIndex(where: { $0.id == forward.id }) else { return }
        forwards[index].spec = moved
        forwards[index].movedByApp = true
        forwards[index].state = .pending
        appendLog(alias, "forward \(forward.spec.sshArgument) moved to local \(moved.localPort)")
        onForwardMoved?(forward.spec, moved)
        await open(forwards[index])
    }

    private func close(_ forward: Forward) async {
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

    private func ensureMaster(_ alias: String) async throws -> SSHMaster {
        if let master = masters[alias], await master.isRunning {
            return master
        }
        if let starting = startingMasters[alias] {
            return try await starting.value
        }
        machineStates[alias] = .connecting
        appendLog(alias, "connecting")
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
            // Everything that wanted this connection may have been switched
            // off while it was starting; do not keep an idle master around.
            guard self.isWanted(alias) else {
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
    private func isWanted(_ alias: String) -> Bool {
        autoHosts.contains(alias) || forwards(on: alias).contains { $0.desiredOn }
    }

    /// The master could not be had: a cancelled start is not a failure, anything
    /// else is, and every desired forward on the machine shows it.
    private func machineFailed(_ alias: String, _ error: Error) {
        if error is CancellationError {
            machineStates[alias] = .disconnected
            return
        }
        machineStates[alias] = .failed(reason: error.localizedDescription)
        for forward in forwards(on: alias) where forward.desiredOn {
            update(forward.id) { $0.state = .dropped }
        }
    }

    private func masterDidExit(alias: String, code: Int32, output: String) async {
        // Ignore exits we asked for.
        guard masters[alias] != nil else {
            appendLog(alias, "(an old connection exited with \(code); ignored)")
            return
        }
        masters[alias] = nil
        appendLog(alias, "connection exited (\(code)) last output: \(output.suffix(160))")
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

    private static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func appendLog(_ alias: String, _ line: String) {
        var lines = logs[alias] ?? []
        lines.append(ForwardController.logTime.string(from: Date()) + "  " + line)
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
