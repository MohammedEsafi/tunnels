import AppKit
import Observation
import ServiceManagement
import TunnelsCore

/// Everything the views read, and the glue between the core and macOS.
@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    let controller: ForwardController
    let reconnector: Reconnector
    let favouritesURL: URL
    let socketDirectory: URL

    private(set) var favourites: [Favourite] = []
    /// Machines known to the favourites file as all-ports hosts.
    private(set) var autoHosts: [AutoHost] = []
    /// The host whose switch was just turned on and needs the question answered.
    var modeQuestion: String?
    private(set) var favouritesProblems: [String] = []
    /// ssh config Hosts first, then Tailscale peers not already covered.
    private(set) var hosts: [HostEntry] = []
    private var sshConfigHosts: [String] = []
    private var tailscaleHosts: [HostEntry] = []
    private(set) var external: [ExternalForward] = []
    private(set) var isRestoring = false
    /// Debug runs turn this off so a throwaway session is not restored later.
    var persistStateOnQuit = true

    /// The popover drives external scanning so `ps` only runs while it is open.
    var popoverVisible = false {
        didSet {
            popoverVisible ? startExternalScanning() : stopExternalScanning()
            if popoverVisible { reloadHosts() } else { quickOpenVisible = false; quickOpenText = ""; menuPage = .main; modeQuestion = nil }
        }
    }

    /// Settings live on pages inside the menu, like Control Center sub-pages.
    enum MenuPage { case main, settings, pinned, logs }
    var menuPage: MenuPage = .main

    /// One notification when a machine gives up reconnecting.
    var notifyOnGiveUp: Bool = UserDefaults.standard.object(forKey: "notifyOnGiveUp") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnGiveUp, forKey: "notifyOnGiveUp") }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func rename(_ favourite: Favourite, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != favourite.name else { return }
        do {
            try Favourites.rename(favourite.spec, to: trimmed, in: favouritesURL)
            reloadFavourites()
        } catch {
            favouritesProblems = [error.localizedDescription]
        }
    }

    /// Forget from the Forwards page: closes it too if it is open.
    func forget(_ favourite: Favourite) {
        if let forward = controller.forwards.first(where: { $0.spec == favourite.spec }) {
            removeForward(forward)
        } else {
            try? Favourites.remove(favourite.spec, from: favouritesURL)
            reloadFavourites()
        }
    }

    /// The host:port field is hidden behind the + button until asked for.
    var quickOpenVisible = false
    /// The field's text lives here so the empty state can prefill "host:".
    var quickOpenText = ""

    func prefillQuickOpen(host: String) {
        quickOpenVisible = true
        quickOpenText = host + ":"
    }

    /// Open ~/.ssh/config in the default editor, creating it if needed.
    func openSSHConfig() {
        let path = SSHConfig.defaultPath
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: path, contents: Data("# Host example\n#   HostName 10.0.0.5\n#   User you\n".utf8), attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// "localhost:<port>" to the clipboard, the usual next step after opening.
    func copyAddress(of spec: ForwardSpec) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("localhost:\(spec.localPort)", forType: .string)
    }

    private let runner = SystemProcessRunner()
    private var watcher: FileWatcher?
    private var healthTask: Task<Void, Never>?
    private var externalTask: Task<Void, Never>?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tunnels")
        let sockets = ProcessInfo.processInfo.environment["TUNNELS_SOCKET_DIR"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("sockets")
        socketDirectory = sockets
        controller = ForwardController(runner: runner, socketDirectory: sockets)
        reconnector = Reconnector(controller: controller)
        favouritesURL = Favourites.defaultURL

        reconnector.onGaveUp = { [weak self] alias, reason in
            guard self?.notifyOnGiveUp ?? true else { return }
            Notifier.post(title: "\(alias) is down", body: "\(reason). Open Tunnels to retry.")
        }
        controller.onOffsetAssigned = { [weak self] alias, offset in
            guard let self else { return }
            try? Favourites.setOffset(offset, forHost: alias, in: favouritesURL)
            reloadFavourites()
            guard notifyOnGiveUp else { return }
            Notifier.post(
                title: "\(alias) ports moved",
                body: "Some ports were taken, so \(alias) uses +\(offset). For example \(8080 + offset) is its 8080."
            )
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

    /// Masters left behind by a crash or force quit would hold our ports.
    private func sweepStaleMasters() async {
        let stale = await ExternalScanner.staleMasters(runner: runner, socketDirectory: socketDirectory)
        for pid in stale {
            ExternalScanner.stop(pid: pid)
            DebugLog.log("stopped stale ssh master \(pid)")
        }
        if !stale.isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // MARK: Favourites and hosts

    func reloadFavourites() {
        autoHosts = Favourites.loadHosts(from: favouritesURL)
        do {
            favourites = try Favourites.load(from: favouritesURL)
            favouritesProblems = []
        } catch let error as FavouritesError {
            favouritesProblems = error.problems
        } catch {
            favouritesProblems = [error.localizedDescription]
        }
        controller.setFavourites(favourites.map { ($0.spec, $0.name) })
        DebugLog.log("favourites: \(favourites.count) from \(favouritesURL.path), problems: \(favouritesProblems), forwards: \(controller.forwards.count)")
    }

    func reloadHosts() {
        sshConfigHosts = SSHConfig.hostAliases()
        mergeHosts()
        Task {
            tailscaleHosts = await TailscaleHosts.fetch(runner: runner)
            mergeHosts()
        }
    }

    private func mergeHosts() {
        var merged = sshConfigHosts.map { HostEntry(name: $0, source: .sshConfig) }
        let known = Set(sshConfigHosts.map { $0.lowercased() })
        for host in tailscaleHosts where !known.contains(host.name) {
            merged.append(host)
        }
        hosts = merged
    }

    func openFavouritesFile() {
        if !FileManager.default.fileExists(atPath: favouritesURL.path) {
            _ = try? Favourites.load(from: favouritesURL)
        }
        NSWorkspace.shared.open(favouritesURL)
    }

    func revealFavouritesFile() {
        NSWorkspace.shared.activateFileViewerSelecting([favouritesURL])
    }

    // MARK: Opening forwards

    func open(_ favourite: Favourite) {
        Task {
            if let existing = controller.forwards.first(where: { $0.spec == favourite.spec }) {
                await controller.setForward(id: existing.id, on: true)
            } else {
                await controller.addAdHoc(favourite.spec, name: favourite.name)
            }
        }
    }

    /// Open and remember. Anything opened from the field goes straight into
    /// the favourites file, so it is back next time; × forgets it.
    func open(_ spec: ForwardSpec) {
        Task {
            await controller.addAdHoc(spec)
            if !favourites.contains(where: { $0.spec == spec }) {
                let name = spec.remoteHost == "localhost" || spec.remoteHost == "127.0.0.1"
                    ? String(spec.remotePort) : "\(spec.remoteHost):\(spec.remotePort)"
                try? Favourites.add(Favourite(name: name, spec: spec), to: favouritesURL)
                reloadFavourites()
            }
        }
    }

    func setForward(_ forward: Forward, on: Bool) {
        if !on { reconnector.cancel(forward.spec.machine) }
        Task { await controller.setForward(id: forward.id, on: on) }
    }

    func setMachine(_ alias: String, on: Bool) {
        if on {
            switchOn(alias)
        } else {
            modeQuestion = nil
            reconnector.cancel(alias)
            Task { await controller.setMachine(alias: alias, on: false) }
        }
    }

    func retryNow(_ alias: String) {
        reconnector.retryNow(alias, userInitiated: true)
    }

    /// "45 seconds", "3 minutes", "2 hours".
    static func describe(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return "\(s) seconds" }
        let m = Int((seconds / 60).rounded())
        if m < 90 { return "\(m) minutes" }
        let h = Int((seconds / 3600).rounded())
        return h == 1 ? "1 hour" : "\(h) hours"
    }

    /// The × on a row: close it and forget it.
    func removeForward(_ forward: Forward) {
        reconnector.cancel(forward.spec.machine)
        try? Favourites.remove(forward.spec, from: favouritesURL)
        reloadFavourites()
        Task { await controller.remove(id: forward.id) }
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

    private func startExternalScanning() {
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

    private func stopExternalScanning() {
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

    // MARK: All ports

    func isAutoHost(_ alias: String) -> Bool {
        autoHosts.contains { $0.name == alias }
    }

    func isWatching(_ alias: String) -> Bool {
        controller.autoHosts.contains(alias)
    }

    /// From the suggestion, or the question: watch every port on the machine.
    /// Saying "all ports" explicitly forgets any "not this one" choices; they
    /// only survive automatic reconnects and relaunches.
    func enableAllPorts(_ alias: String) {
        modeQuestion = nil
        if !isAutoHost(alias) {
            try? Favourites.addHost(AutoHost(name: alias), to: favouritesURL)
        } else {
            try? Favourites.setExcluded([], forHost: alias, in: favouritesURL)
        }
        reloadFavourites()
        let offset = autoHosts.first { $0.name == alias }?.offset
        controller.enableAutoHost(alias, excluded: [], offset: offset)
    }

    /// At launch: resume watching with the exclusions and offset on file.
    private func resumeAllPorts(_ alias: String) {
        let host = autoHosts.first { $0.name == alias }
        controller.enableAutoHost(alias, excluded: host?.excluded ?? [], offset: host?.offset)
    }

    /// The question's other answer: freeze what all-ports mode had found.
    /// The ports open when the host was switched off, minus the ones closed,
    /// become ordinary pinned forwards, and watching stops for good.
    func enablePinnedOnly(_ alias: String) {
        modeQuestion = nil
        let pinnedAlready = Set(favourites.filter { $0.spec.machine == alias }.map(\.spec.localPort))
        let frozen = (controller.lastDiscovered[alias] ?? []).subtracting(pinnedAlready)
        for port in frozen.sorted() {
            try? Favourites.add(Favourite(name: String(port), spec: ForwardSpec(machine: alias, localPort: port)), to: favouritesURL)
        }
        try? Favourites.removeHost(alias, from: favouritesURL)
        reloadFavourites()
        Task {
            await controller.disableAutoHost(alias)
            await controller.setMachine(alias: alias, on: true)
        }
    }

    /// Switch on a host: ask when it is an all-ports host, otherwise just open.
    func switchOn(_ alias: String) {
        if isAutoHost(alias) {
            modeQuestion = alias
        } else {
            Task { await controller.setMachine(alias: alias, on: true) }
        }
    }

    /// "Not this one" on a discovered row.
    func excludePort(_ forward: Forward) {
        let alias = forward.spec.machine
        Task {
            await controller.excludePort(forward.spec.localPort, on: alias)
            do {
                let written = try Favourites.setExcluded(controller.autoExcluded[alias] ?? [], forHost: alias, in: favouritesURL)
                DebugLog.log("exclude \(forward.spec.localPort) on \(alias): now \(controller.autoExcluded[alias] ?? []), written=\(written)")
            } catch {
                DebugLog.log("exclude \(forward.spec.localPort) on \(alias): write failed \(error)")
            }
            reloadFavourites()
        }
    }

    /// × on an all-ports host row: stop watching and forget the mode.
    func forgetAutoHost(_ alias: String) {
        modeQuestion = nil
        try? Favourites.removeHost(alias, from: favouritesURL)
        reloadFavourites()
        Task { await controller.disableAutoHost(alias) }
    }

    func external(on alias: String) -> [ExternalForward] {
        external.filter { $0.spec.machine == alias }
    }

    // MARK: Health and persistence

    private func startHealthChecks() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.controller.healthCheck()
            }
        }
    }

    /// Bring back what was on at the last quit. Machines are restored in
    /// parallel so one that is unreachable cannot hold the others up.
    private func restoreState() async {
        let state = PersistedState.load()
        guard !state.onForwards.isEmpty || !state.autoHostsOn.isEmpty else { return }
        isRestoring = true
        defer { isRestoring = false }
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

    func prepareForQuit() async {
        DebugLog.log("prepareForQuit: saving state and closing \(controller.machines.count) machine(s)")
        if persistStateOnQuit { PersistedState.capture(from: controller).save() }
        for alias in controller.machines { reconnector.cancel(alias) }
        await controller.shutdown()
        DebugLog.log("prepareForQuit: done")
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
