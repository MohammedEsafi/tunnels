import AppKit
import Observation
import ServiceManagement
import TunnelsCore

/// Everything the views read, and the glue between the core and macOS.
@Observable
@MainActor
final class AppModel {
    /// The engine. Views never touch it: they read through the accessors
    /// below and act through the methods in the extension files.
    let controller: ForwardController
    let reconnector: Reconnector
    let favouritesURL: URL
    let socketDirectory: URL
    /// TUNNELS_SSH_CONFIG=/path makes every ssh call and the host list use
    /// that config instead of ~/.ssh/config. A development aid, unset normally.
    let sshConfigPath: String
    let runner = SystemProcessRunner()
    var watcher: FileWatcher?
    var healthTask: Task<Void, Never>?
    var externalTask: Task<Void, Never>?

    var favourites: [Favourite] = []
    /// Machines known to the favourites file as all-ports hosts.
    var autoHosts: [AutoHost] = []
    var favouritesProblems: [String] = []
    /// ssh config Hosts first, then Tailscale peers not already covered.
    private(set) var hosts: [HostEntry] = []
    var sshConfigHosts: [String] = []
    var tailscaleHosts: [HostEntry] = []
    private(set) var external: [ExternalForward] = []
    /// Debug runs turn this off so a throwaway session is not restored later.
    var persistStateOnQuit = true

    /// The popover drives external scanning so `ps` only runs while it is open.
    var popoverVisible = false {
        didSet {
            DebugLog.log("panel \(popoverVisible ? "shown" : "hidden")")
            popoverVisible ? startExternalScanning() : stopExternalScanning()
            if popoverVisible { reloadHosts() } else { quickOpenVisible = false; quickOpenText = ""; menuPage = .main }
        }
    }

    /// Settings live on pages inside the menu, like Control Center sub-pages.
    enum MenuPage { case main, settings, logs }
    var menuPage: MenuPage = .main
    /// How tall the scrolling list may grow: set from the screen the panel
    /// opens on, so the menu never runs off the bottom of a small display.
    var maxListHeight: CGFloat = 620

    /// Whether to post notifications: a machine giving up, coming back, or
    /// getting an offset.
    var notifyOnGiveUp: Bool = UserDefaults.standard.object(forKey: "notifyOnGiveUp") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyOnGiveUp, forKey: "notifyOnGiveUp")
            // Ask while the user is looking at the switch, not when a machine drops.
            if notifyOnGiveUp { Notifier.requestAuthorization() }
        }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The host:port field is hidden behind the + button until asked for.
    var quickOpenVisible = false
    /// The field's text lives here so the empty state can prefill "host:".
    var quickOpenText = ""

    /// Which machine the Connection Logs page should open on.
    var logSelection: String?
    /// Debug only: a row that should open its port editor when it appears.
    var debugEditPort: ForwardSpec?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tunnels")
        let sockets = ProcessInfo.processInfo.environment["TUNNELS_SOCKET_DIR"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("sockets")
        socketDirectory = sockets
        let configOverride = ProcessInfo.processInfo.environment["TUNNELS_SSH_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        sshConfigPath = configOverride ?? SSHConfig.defaultPath
        controller = ForwardController(runner: runner, options: SSHOptions(socketDirectory: sockets, configPath: configOverride))
        reconnector = Reconnector(controller: controller)
        favouritesURL = Favourites.defaultURL

        reconnector.onGaveUp = { [weak self] alias, reason in
            guard self?.notifyOnGiveUp ?? true else { return }
            Notifier.post(title: "\(alias) is down", body: "\(reason). Open Tunnels to retry.")
        }
        controller.onOffsetAssigned = { [weak self] alias, offset in
            guard let self else { return }
            editFavourites("setOffset") { try Favourites.setOffset(offset, forHost: alias, in: self.favouritesURL) }
            reloadFavourites()
            guard notifyOnGiveUp else { return }
            Notifier.post(
                title: "\(alias) ports moved",
                body: "Some ports were taken, so \(alias) uses +\(offset). For example \(8080 + offset) is its 8080."
            )
        }
        controller.onForwardMoved = { [weak self] old, new in
            guard let self else { return }
            editFavourites("changeLocalPort") { try Favourites.changeLocalPort(old, to: new.localPort, movedByApp: new.localPort != new.remotePort, in: self.favouritesURL) }
            reloadFavourites()
        }
        reconnector.onReconnected = { [weak self] alias, elapsed in
            guard let self, notifyOnGiveUp else { return }
            let open = controller.forwards(on: alias).filter { $0.state == .active }.count
            let forwards = open == 1 ? "1 forward open" : "\(open) forwards open"
            Notifier.post(title: "\(alias) is back", body: "Reconnected after \(Self.describe(elapsed)). \(forwards).")
        }

        reloadFavourites()
        reloadHosts()
        watcher = FileWatcher(url: favouritesURL) { [weak self] in
            self?.reloadFavourites()
        }
        SystemEvents.shared.start { [weak self] in
            self?.reconnector.systemDidChange()
        }
        startHealthChecks()
        Task {
            await sweepStaleMasters()
            await restoreState()
        }
    }

    // MARK: What the views read

    func forwards(on alias: String) -> [Forward] { controller.forwards(on: alias) }
    func machineState(_ alias: String) -> MachineState { controller.machineState(alias) }
    var anyDesired: Bool { controller.anyDesired }
    var loggedAliases: [String] { controller.logs.keys.sorted() }
    func log(for alias: String) -> [String]? { controller.logs[alias] }
    func isOn(_ favourite: Favourite) -> Bool {
        controller.forwards.first { $0.spec == favourite.spec }?.desiredOn ?? false
    }

    /// Masters left behind by a crash or force quit would hold our ports.
    func sweepStaleMasters() async {
        let stale = await ExternalScanner.staleMasters(runner: runner, socketDirectory: socketDirectory)
        for pid in stale {
            ExternalScanner.stop(pid: pid)
            DebugLog.log("stopped stale ssh master \(pid)")
        }
        if !stale.isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    func reloadHosts() {
        sshConfigHosts = SSHConfig.hostAliases(configPath: sshConfigPath)
        mergeHosts()
        Task {
            tailscaleHosts = await TailscaleHosts.fetch(runner: runner)
            mergeHosts()
        }
    }

    func mergeHosts() {
        var merged = sshConfigHosts.map { HostEntry(name: $0, source: .sshConfig) }
        let known = Set(sshConfigHosts.map { $0.lowercased() })
        for host in tailscaleHosts where !known.contains(host.name) {
            merged.append(host)
        }
        hosts = merged
    }

    func setForward(_ forward: Forward, on: Bool) {
        if !on { reconnector.cancel(forward.spec.machine) }
        Task { await controller.setForward(id: forward.id, on: on) }
    }

    func setMachine(_ alias: String, on: Bool) {
        if on {
            switchOn(alias)
        } else {
            reconnector.cancel(alias)
            Task { await controller.setMachine(alias: alias, on: false) }
        }
    }

    func retryNow(_ alias: String) {
        reconnector.retryNow(alias, userInitiated: true)
    }

    func closeAll() {
        for alias in controller.machines { reconnector.cancel(alias) }
        Task { await controller.closeAll() }
    }

    func reopenAll() {
        for alias in controller.machines {
            switch controller.machineState(alias) {
            case .dropped, .failed: reconnector.retryNow(alias)
            default: continue
            }
        }
        Task { await controller.reopenAll() }
    }

    // MARK: Forwards started elsewhere

    func startExternalScanning() {
        externalTask?.cancel()
        externalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let found = await ExternalScanner.scan(runner: runner)
                if !Task.isCancelled { self.external = found }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stopExternalScanning() {
        externalTask?.cancel()
        externalTask = nil
    }

    func stopExternal(_ forward: ExternalForward) {
        ExternalScanner.stop(pid: forward.pid)
        external.removeAll { $0.pid == forward.pid }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            external = await ExternalScanner.scan(runner: runner)
        }
    }

    /// Aliases shown in the popover: machines with app forwards, all-ports
    /// hosts (on or off), plus those that only have outside forwards.
    var sectionAliases: [String] {
        Array(Set(controller.machines).union(external.map(\.spec.machine)).union(autoHosts.map(\.name))).sorted()
    }

    func external(on alias: String) -> [ExternalForward] {
        external.filter { $0.spec.machine == alias }
    }

    // MARK: Health and persistence

    func startHealthChecks() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.controller.healthCheck()
            }
        }
    }

    /// Bring back what was on at the last quit. Machines are restored in
    /// parallel so one that is unreachable cannot hold the others up.
    func restoreState() async {
        let state = PersistedState.load()
        guard !state.onForwards.isEmpty || !state.autoHostsOn.isEmpty else { return }
        for alias in state.autoHostsOn where isAutoHost(alias) {
            resumeAllPorts(alias)
        }
        let byMachine = Dictionary(grouping: state.onForwards, by: \.spec.machine)
        await withTaskGroup(of: Void.self) { group in
            for (_, entries) in byMachine {
                group.addTask { @MainActor in
                    for entry in entries {
                        if let existing = self.controller.forwards.first(where: { $0.spec == entry.spec }) {
                            await self.controller.setForward(id: existing.id, on: true)
                        } else {
                            await self.controller.addAdHoc(entry.spec, name: entry.name)
                        }
                    }
                }
            }
        }
    }

    func prepareForQuitNow() {
        DebugLog.log("prepareForQuitNow: saving state and closing \(controller.machines.count) machine(s)")
        if persistStateOnQuit { PersistedState.capture(from: controller).save() }
        for alias in controller.machines { reconnector.cancel(alias) }
        controller.shutdownNow()
        DebugLog.log("prepareForQuitNow: done")
    }

}
