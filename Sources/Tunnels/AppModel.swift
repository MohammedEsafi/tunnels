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

    private(set) var favourites: [Favourite] = []
    private(set) var favouritesProblems: [String] = []
    private(set) var hosts: [String] = []
    private(set) var external: [ExternalForward] = []
    private(set) var isRestoring = false
    /// Debug runs turn this off so a throwaway session is not restored later.
    var persistStateOnQuit = true

    /// The popover drives external scanning so `ps` only runs while it is open.
    var popoverVisible = false {
        didSet {
            popoverVisible ? startExternalScanning() : stopExternalScanning()
            if !popoverVisible { quickOpenVisible = false; quickOpenText = "" }
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
        controller = ForwardController(runner: runner, socketDirectory: support.appendingPathComponent("sockets"))
        reconnector = Reconnector(controller: controller)
        favouritesURL = Favourites.defaultURL

        reconnector.onGaveUp = { alias, reason in
            Notifier.post(title: "\(alias) is down", body: "\(reason). Open Tunnels to retry.")
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
        Task { await restoreState() }
    }

    // MARK: Favourites and hosts

    func reloadFavourites() {
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
        hosts = SSHConfig.hostAliases()
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

    func open(_ spec: ForwardSpec) {
        Task { await controller.addAdHoc(spec) }
    }

    func setForward(_ forward: Forward, on: Bool) {
        if !on { reconnector.cancel(forward.spec.machine) }
        Task { await controller.setForward(id: forward.id, on: on) }
    }

    func setMachine(_ alias: String, on: Bool) {
        if !on { reconnector.cancel(alias) }
        Task { await controller.setMachine(alias: alias, on: on) }
    }

    func retryNow(_ alias: String) {
        reconnector.retryNow(alias)
    }

    /// Star / unstar from the row. Writes the favourites file; the watcher
    /// reloads it and the row keeps its state either way.
    func toggleFavourite(_ forward: Forward) {
        do {
            if forward.isFavourite {
                try Favourites.remove(forward.spec, from: favouritesURL)
            } else {
                try Favourites.add(Favourite(name: forward.name, spec: forward.spec), to: favouritesURL)
            }
            reloadFavourites()
        } catch {
            favouritesProblems = [error.localizedDescription]
        }
    }

    func removeAdHoc(_ forward: Forward) {
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

    /// Aliases shown in the popover: machines with app forwards plus those
    /// that only have forwards from other ssh processes.
    var sectionAliases: [String] {
        Array(Set(controller.machines).union(external.map(\.spec.machine))).sorted()
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

    private func restoreState() async {
        let state = PersistedState.load()
        guard !state.onForwards.isEmpty else { return }
        isRestoring = true
        defer { isRestoring = false }
        for entry in state.onForwards {
            if let existing = controller.forwards.first(where: { $0.spec == entry.spec }) {
                await controller.setForward(id: existing.id, on: true)
            } else {
                await controller.addAdHoc(entry.spec, name: entry.name)
            }
        }
    }

    /// Called from applicationShouldTerminate on the main thread; must not await.
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
