import Foundation

/// All-ports mode: watch a machine, forward every listener it has, and keep
/// every discovered port on one offset when plain numbers clash.
extension ForwardController {
    /// Watch a machine and forward every listener it has, except `excluded`.
    public func enableAutoHost(_ alias: String, excluded: Set<Int> = [], offset: Int? = nil) {
        autoExcluded[alias] = excluded
        if let offset { offsets[alias] = offset }
        guard !autoHosts.contains(alias) else { return }
        autoHosts.insert(alias)
        // A machine the reconnector gave up on starts afresh here; scans
        // would otherwise keep deferring to a reconnector that is done.
        if case .failed = machineState(alias), masters[alias] == nil, startingMasters[alias] == nil {
            machineStates[alias] = .disconnected
        }
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
        if !forwards(on: alias).contains(where: { $0.desiredOn }) {
            if let master = masters[alias] {
                await master.stop()
                masters[alias] = nil
            }
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

    /// One discovery pass: add forwards for new listeners, drop vanished ones,
    /// retry the ones that failed (a local port may have freed up).
    public func scan(_ alias: String) async {
        guard autoHosts.contains(alias), !scanning.contains(alias) else { return }
        // After a drop the reconnector owns the retries, with its backoff and
        // its give-up; scanning again here would race it and make "is down"
        // untrue. While an attempt is connecting, joining it would report its
        // failure a second time and restart the backoff. The next scan runs
        // once the machine is connected.
        switch machineState(alias) {
        case .dropped, .failed, .connecting: return
        default: break
        }
        scanning.insert(alias)
        defer { scanning.remove(alias) }
        let master: SSHMaster
        do {
            master = try await ensureMaster(alias)
        } catch {
            machineFailed(alias, error)
            if !(error is CancellationError) { onMasterDropped?(alias, error.localizedDescription) }
            return
        }
        // The host can be switched off during any of the awaits below; a scan
        // that carried on would reopen what the switch just closed.
        guard autoHosts.contains(alias), let output = try? await master.run(PortDiscovery.command), autoHosts.contains(alias) else {
            if autoHosts.contains(alias) { appendLog(alias, "scan: could not list ports") }
            return
        }
        let excluded = autoExcluded[alias] ?? []
        let pinnedRemote = Set(
            forwards(on: alias).filter {
                !$0.isDiscovered && $0.spec.isLoopbackRemote
            }.map(\.spec.remotePort))
        let wanted = PortDiscovery.parse(output).subtracting(excluded).subtracting(pinnedRemote)
        lastDiscovered[alias] = wanted
        let current = forwards(on: alias).filter(\.isDiscovered)
        appendLog(
            alias,
            "scan: listening \(PortDiscovery.parse(output).sorted()) excluded \(excluded.sorted()) have \(current.map(\.spec.remotePort).sorted())"
        )

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
    func openDiscovered(_ port: Int, on alias: String) async {
        if offsets[alias] == nil {
            let plain = Forward(
                spec: ForwardSpec(machine: alias, localPort: port), name: String(port), isFavourite: false, isDiscovered: true,
                desiredOn: true)
            if !isLocalPortTaken(port) {
                forwards.append(plain)
                await open(plain)
                guard case .error(let reason) = forwards.first(where: { $0.id == plain.id })?.state,
                    reason == "Local port in use"
                else { return }
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

    func openMoved(_ port: Int, on alias: String, offset: Int) async {
        let moved = Forward(
            spec: ForwardSpec(machine: alias, localPort: port + offset, remotePort: port), name: String(port), isFavourite: false,
            isDiscovered: true, desiredOn: true)
        forwards.append(moved)
        await open(moved)
    }

    /// Forget a machine's offset; its next scan tries plain numbers again.
    public func clearOffset(_ alias: String) {
        offsets[alias] = nil
    }

    /// Something of ours already listens there, so do not even try the plain number.
    /// Taken by one of our own forwards, or by any other program on this Mac.
    func isLocalPortTaken(_ port: Int) -> Bool {
        forwards.contains { $0.spec.localPort == port && ($0.state == .active || $0.state == .noService) } || localPortProbe(port)
    }

    func nextOffset() -> Int {
        var candidate = 10000
        while offsets.values.contains(candidate) { candidate += 10000 }
        return candidate
    }

    /// Put a moved pinned forward back on its plain number if that binds;
    /// otherwise carry on with the moved number.
    func tryPlain(_ forward: Forward) async {
        let alias = forward.spec.machine
        let plain = ForwardSpec(
            machine: alias, localPort: forward.spec.remotePort, remoteHost: forward.spec.remoteHost, remotePort: forward.spec.remotePort)
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
            keep.movedByApp = false  // so this pass does not loop
            update(forward.id) { $0.movedByApp = false }
            await open(keep)
            update(forward.id) { $0.movedByApp = true }
        }
    }

    /// A pinned forward whose plain number is taken moves to remote + the
    /// machine's offset, assigning one if needed, like a discovered port.
    func movePinned(_ forward: Forward) async {
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
        let moved = ForwardSpec(
            machine: alias, localPort: forward.spec.remotePort + offset, remoteHost: forward.spec.remoteHost,
            remotePort: forward.spec.remotePort)
        guard !forwards.contains(where: { $0.spec == moved }),
            let index = forwards.firstIndex(where: { $0.id == forward.id })
        else { return }
        forwards[index].spec = moved
        forwards[index].movedByApp = true
        forwards[index].state = .pending
        appendLog(alias, "forward \(forward.spec.sshArgument) moved to local \(moved.localPort)")
        onForwardMoved?(forward.spec, moved)
        await open(forwards[index])
    }
}
