import Foundation

public struct Favourite: Equatable, Hashable, Sendable {
    public var name: String
    public var spec: ForwardSpec

    public init(name: String, spec: ForwardSpec) {
        self.name = name
        self.spec = spec
    }
}

public struct FavouritesError: Error, Equatable, LocalizedError {
    public let problems: [String]
    public var errorDescription: String? { problems.joined(separator: "\n") }
}

public enum Favourites {
    /// $XDG_CONFIG_HOME/tunnels/favourites.toml, default ~/.config/tunnels/favourites.toml
    public static var defaultURL: URL {
        let base: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else {
            base = NSHomeDirectory() + "/.config"
        }
        return URL(fileURLWithPath: base).appendingPathComponent("tunnels/favourites.toml")
    }

    public static let template = """
    # Tunnels favourites. One [[favourite]] per forward.
    #
    #   name        label shown in the menu
    #   host        a Host alias from ~/.ssh/config
    #   port        local port on this Mac (127.0.0.1 only)
    #   remote_port port on the remote side, defaults to `port`
    #   remote_host host as seen from the machine, defaults to "localhost"
    #
    # Example:
    #
    # [[favourite]]
    # name = "postgres"
    # host = "prod-db-01"
    # port = 5432
    #
    # [[favourite]]
    # name = "postgres"
    # host = "staging"
    # port = 15432
    # remote_port = 5432

    """

    /// Load the file, creating a commented template on first run.
    public static func load(from url: URL = defaultURL) throws -> [Favourite] {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
            return []
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> [Favourite] {
        let root: [String: TOMLValue]
        do {
            root = try MiniTOML.parse(text)
        } catch let error as TOMLError {
            throw FavouritesError(problems: [error.errorDescription ?? "parse error"])
        }
        guard let entries = root["favourite"] else { return [] }
        guard let tables = entries.tables else {
            throw FavouritesError(problems: ["favourite must be written as [[favourite]] tables"])
        }

        var problems: [String] = []
        var result: [Favourite] = []
        var seen: Set<String> = []
        for (index, table) in tables.enumerated() {
            let label = "favourite #\(index + 1)"
            guard let host = table["host"]?.string?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
                problems.append("\(label): host is required")
                continue
            }
            guard let port = table["port"]?.integer else {
                problems.append("\(label) (\(host)): port is required and must be a number")
                continue
            }
            guard (1...65535).contains(port) else {
                problems.append("\(label) (\(host)): port \(port) is out of range")
                continue
            }
            let remotePort = table["remote_port"]?.integer ?? port
            guard (1...65535).contains(remotePort) else {
                problems.append("\(label) (\(host)): remote_port \(remotePort) is out of range")
                continue
            }
            let remoteHost = table["remote_host"]?.string ?? "localhost"
            let name = table["name"]?.string?.trimmingCharacters(in: .whitespaces)
            let spec = ForwardSpec(machine: host, localPort: port, remoteHost: remoteHost, remotePort: remotePort)
            let key = "\(host):\(port)"
            if seen.contains(key) {
                problems.append("\(label): \(host) port \(port) is listed twice")
                continue
            }
            seen.insert(key)
            result.append(Favourite(name: (name?.isEmpty == false ? name! : "\(remotePort)"), spec: spec))
        }
        if !problems.isEmpty { throw FavouritesError(problems: problems) }
        return result
    }
}

/// Watches a file and its directory, since most editors replace files rather
/// than writing in place. Fires on the main queue after a short debounce.
public final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        watchDirectory()
        watchFile()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    private func watchDirectory() {
        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.watchFile()
            self?.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            self?.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
