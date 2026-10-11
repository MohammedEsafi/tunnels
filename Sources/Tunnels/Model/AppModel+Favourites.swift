import AppKit
import TunnelsCore

/// The favourites file: everything typed or discovered that the user keeps.
extension AppModel {
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

    func renameForward(_ forward: Forward, to name: String) {
        if forward.isDiscovered {
            pinDiscovered(forward, name: name)
            return
        }
        guard let favourite = favourites.first(where: { $0.spec == forward.spec }) else { return }
        rename(favourite, to: name)
    }

    /// Move a forward to other ports: rewrite the file, then reopen it on the
    /// new numbers if it was on (or as `on` says). A discovered port keeps its
    /// remote number, since that is what was found on the machine.
    func changePorts(_ forward: Forward, local: Int, remote: Int, on: Bool? = nil) {
        let remote = forward.isDiscovered ? forward.spec.remotePort : remote
        let moved = ForwardSpec(machine: forward.spec.machine, localPort: local, remoteHost: forward.spec.remoteHost, remotePort: remote)
        guard (1...65535).contains(local), (1...65535).contains(remote) else { return }
        guard moved != forward.spec else {
            if let on, on != forward.desiredOn { setForward(forward, on: on) }
            return
        }
        let wantOn = on ?? forward.desiredOn
        Task {
            if forward.isDiscovered {
                // Pin it on the new number; discovery then leaves this remote port alone.
                await controller.excludePort(remotePort: forward.spec.remotePort, on: forward.spec.machine)
                editFavourites("setExcluded") { try Favourites.setExcluded(controller.autoExcluded[forward.spec.machine] ?? [], forHost: forward.spec.machine, in: self.favouritesURL) }
                editFavourites("add") { try Favourites.add(Favourite(name: forward.name, spec: moved), to: self.favouritesURL) }
                reloadFavourites()
                if wantOn, let pinned = controller.forwards.first(where: { $0.spec == moved }) {
                    await controller.setForward(id: pinned.id, on: true)
                }
                return
            }
            await controller.remove(id: forward.id)
            editFavourites("changePorts") { try Favourites.changePorts(forward.spec, local: local, remote: remote, in: self.favouritesURL) }
            reloadFavourites()
            if wantOn, let pinned = controller.forwards.first(where: { $0.spec == moved }) {
                await controller.setForward(id: pinned.id, on: true)
            }
        }
    }

    /// A discovered port becomes an ordinary pinned forward with a name.
    func pinDiscovered(_ forward: Forward, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        editFavourites("add") { try Favourites.add(Favourite(name: trimmed.isEmpty ? forward.name : trimmed, spec: forward.spec), to: self.favouritesURL) }
        reloadFavourites()
    }

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
        controller.setFavourites(favourites)
        DebugLog.log("favourites: \(favourites.count) from \(favouritesURL.path), problems: \(favouritesProblems), forwards: \(controller.forwards.count)")
    }

    func openFavouritesFile() {
        if !FileManager.default.fileExists(atPath: favouritesURL.path) {
            _ = try? Favourites.load(from: favouritesURL)
        }
        NSWorkspace.shared.open(favouritesURL)
    }

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
                let name = spec.isLoopbackRemote
                    ? String(spec.remotePort) : "\(spec.remoteHost):\(spec.remotePort)"
                editFavourites("add") { try Favourites.add(Favourite(name: name, spec: spec), to: self.favouritesURL) }
                reloadFavourites()
            }
        }
    }

    /// The × on a row: close it and forget it.
    func removeForward(_ forward: Forward) {
        reconnector.cancel(forward.spec.machine)
        editFavourites("remove") { try Favourites.remove(forward.spec, from: self.favouritesURL) }
        reloadFavourites()
        Task { await controller.remove(id: forward.id) }
    }

    /// Edits to the favourites file are best effort from the menu's point of
    /// view: the in-memory state changes either way, and a failed write is logged.
    @discardableResult
    func editFavourites<T>(_ action: String, _ edit: () throws -> T) -> T? {
        do {
            return try edit()
        } catch {
            DebugLog.log("favourites: \(action) failed: \(error)")
            return nil
        }
    }
}
