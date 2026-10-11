import AppKit
import TunnelsCore

/// All-ports mode as the menu drives it: switching it on and off, exclusions, forgetting.
extension AppModel {
    func isAutoHost(_ alias: String) -> Bool {
        autoHosts.contains { $0.name == alias }
    }

    func isWatching(_ alias: String) -> Bool {
        controller.autoHosts.contains(alias)
    }

    /// From the suggestion or the host's menu: watch every port on the machine.
    /// Saying "all ports" explicitly is a fresh start for that machine: it
    /// forgets "not this one" choices and any offset. Both survive automatic
    /// reconnects and relaunches otherwise.
    func enableAllPorts(_ alias: String) {
        if !isAutoHost(alias) {
            editFavourites("addHost") { try Favourites.addHost(AutoHost(name: alias), to: self.favouritesURL) }
        } else {
            editFavourites("setExcluded") { try Favourites.setExcluded([], forHost: alias, in: self.favouritesURL) }
            editFavourites("setOffset") { try Favourites.setOffset(nil, forHost: alias, in: self.favouritesURL) }
        }
        reloadFavourites()
        // A real restart: drop what discovery had, forget the offset, scan afresh.
        Task {
            await controller.disableAutoHost(alias)
            controller.clearOffset(alias)
            controller.enableAutoHost(alias, excluded: [], offset: nil)
            if controller.forwards(on: alias).contains(where: { !$0.isDiscovered }) {
                await controller.setMachine(alias: alias, on: true)
            }
        }
    }

    /// At launch: resume watching with the exclusions and offset on file, and
    /// reopen pinned forwards on the same machine as they were (no "try the
    /// plain number" pass; that is for a switch-on by hand).
    func resumeAllPorts(_ alias: String) {
        let host = autoHosts.first { $0.name == alias }
        controller.enableAutoHost(alias, excluded: host?.excluded ?? [], offset: host?.offset)
    }

    /// Pinned Ports Only from the host's menu: freeze what all-ports mode had found.
    /// The ports open when the host was switched off, minus the ones closed,
    /// become ordinary pinned forwards, and watching stops for good.
    func enablePinnedOnly(_ alias: String) {
        let pinnedAlready = Set(favourites.filter { $0.spec.machine == alias }.map(\.spec.localPort))
        let frozen = (controller.lastDiscovered[alias] ?? []).subtracting(pinnedAlready)
        for port in frozen.sorted() {
            editFavourites("add") {
                try Favourites.add(
                    Favourite(name: String(port), spec: ForwardSpec(machine: alias, localPort: port)), to: self.favouritesURL)
            }
        }
        editFavourites("removeHost") { try Favourites.removeHost(alias, from: self.favouritesURL) }
        reloadFavourites()
        Task {
            await controller.disableAutoHost(alias)
            await controller.setMachine(alias: alias, on: true)
        }
    }

    /// Switch on a host: an all-ports host resumes watching with its
    /// exclusions but drops its offset, so plain numbers get another try; any
    /// other host just reopens its pinned forwards. The mode itself is changed
    /// from the host's right-click menu.
    func switchOn(_ alias: String) {
        if isAutoHost(alias) {
            let host = autoHosts.first { $0.name == alias }
            editFavourites("setOffset") { try Favourites.setOffset(nil, forHost: alias, in: self.favouritesURL) }
            reloadFavourites()
            controller.enableAutoHost(alias, excluded: host?.excluded ?? [], offset: nil)
        }
        Task { await controller.setMachine(alias: alias, on: true) }
    }

    /// "Not this one" on a discovered row.
    func excludePort(_ forward: Forward) {
        let alias = forward.spec.machine
        Task {
            await controller.excludePort(remotePort: forward.spec.remotePort, on: alias)
            editFavourites("setExcluded") {
                try Favourites.setExcluded(controller.autoExcluded[alias] ?? [], forHost: alias, in: self.favouritesURL)
            }
            reloadFavourites()
        }
    }

    /// Everything about a machine goes: connection, pinned forwards, all-ports
    /// entry. The machine itself still exists in ssh config or Tailscale.
    func forgetMachine(_ alias: String) {
        reconnector.cancel(alias)
        for favourite in favourites where favourite.spec.machine == alias {
            editFavourites("remove") { try Favourites.remove(favourite.spec, from: self.favouritesURL) }
        }
        editFavourites("removeHost") { try Favourites.removeHost(alias, from: self.favouritesURL) }
        Task {
            await controller.disableAutoHost(alias)
            await controller.setMachine(alias: alias, on: false)
            for forward in controller.forwards(on: alias) {
                await controller.remove(id: forward.id)
            }
            reloadFavourites()
        }
    }
}
