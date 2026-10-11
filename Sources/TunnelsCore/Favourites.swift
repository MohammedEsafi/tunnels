import Foundation

public struct Favourite: Equatable, Hashable, Sendable {
    public var name: String
    public var spec: ForwardSpec
    /// `moved = true` in the file: the app chose this local port, not you.
    public var movedByApp: Bool

    public init(name: String, spec: ForwardSpec, movedByApp: Bool = false) {
        self.name = name
        self.spec = spec
        self.movedByApp = movedByApp
    }
}

/// A machine in all-ports mode: every listener it has gets a forward,
/// except the excluded ports.
public struct AutoHost: Equatable, Hashable, Sendable {
    public var name: String
    public var excluded: Set<Int>
    /// Added to a remote port when its plain local number was taken.
    public var offset: Int?

    public init(name: String, excluded: Set<Int> = [], offset: Int? = nil) {
        self.name = name
        self.excluded = excluded
        self.offset = offset
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

    /// The [[host]] entries: machines in all-ports mode.
    public static func loadHosts(from url: URL = defaultURL) -> [AutoHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return (try? parseHosts(text)) ?? []
    }

    public static func parseHosts(_ text: String) throws -> [AutoHost] {
        let root = try MiniTOML.parse(text)
        guard let tables = root["host"]?.tables else { return [] }
        return tables.compactMap { table in
            guard let name = table["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  table["all_ports"]?.boolean ?? true else { return nil }
            let excluded = Set((table["exclude"].flatMap { value -> [Int]? in
                if case .array(let items) = value { return items.compactMap(\.integer) }
                return nil
            }) ?? [])
            return AutoHost(name: name, excluded: excluded, offset: table["offset"]?.integer)
        }
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
            result.append(Favourite(name: (name?.isEmpty == false ? name! : "\(remotePort)"), spec: spec, movedByApp: table["moved"]?.boolean ?? false))
        }
        if !problems.isEmpty { throw FavouritesError(problems: problems) }
        return result
    }
}

// MARK: Writing

public extension Favourites {
    /// One [[favourite]] block. Only non-default keys are written.
    static func serialize(_ favourite: Favourite) -> String {
        var lines = [
            "[[favourite]]",
            "name = \"\(escape(favourite.name))\"",
            "host = \"\(escape(favourite.spec.machine))\"",
            "port = \(favourite.spec.localPort)",
        ]
        if favourite.spec.remotePort != favourite.spec.localPort {
            lines.append("remote_port = \(favourite.spec.remotePort)")
        }
        if favourite.spec.remoteHost != "localhost" {
            lines.append("remote_host = \"\(escape(favourite.spec.remoteHost))\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Append a favourite to the file, creating it (with the template) if needed.
    static func add(_ favourite: Favourite, to url: URL = defaultURL) throws {
        try appendBlock(serialize(favourite), to: url)
    }

    /// Remove the [[favourite]] block whose host and port match. Other blocks
    /// and their comments are left exactly as they were.
    @discardableResult
    static func remove(_ spec: ForwardSpec, from url: URL = defaultURL) throws -> Bool {
        try editBlock("favourite", in: url, matching: { $0.isFavourite(spec) }) { _ in nil }
    }

    /// Change the name of the [[favourite]] block matching host and port,
    /// touching no other line.
    @discardableResult
    static func rename(_ spec: ForwardSpec, to name: String, in url: URL = defaultURL) throws -> Bool {
        try editBlock("favourite", in: url, matching: { $0.isFavourite(spec) }) { lines in
            var lines = lines
            let nameLine = "name = \"\(escape(name))\""
            if let existing = lines.firstIndex(where: { key(of: $0) == "name" }) {
                lines[existing] = nameLine
            } else {
                lines.insert(nameLine, at: 1)
            }
            return lines
        }
    }

    /// Change the local port of the [[favourite]] block matching host and port.
    /// `movedByApp` records whether the app chose the new number.
    @discardableResult
    static func changeLocalPort(_ spec: ForwardSpec, to newPort: Int, movedByApp: Bool = false, in url: URL = defaultURL) throws -> Bool {
        try changePorts(spec, local: newPort, remote: spec.remotePort, movedByApp: movedByApp, in: url)
    }

    /// Change the local and remote ports of the [[favourite]] block matching
    /// host and port. `remote_port` is written only when it differs from `port`.
    @discardableResult
    static func changePorts(_ spec: ForwardSpec, local: Int, remote: Int, movedByApp: Bool = false, in url: URL = defaultURL) throws -> Bool {
        try editBlock("favourite", in: url, matching: { $0.isFavourite(spec) }) { lines in
            guard let portLine = lines.firstIndex(where: { key(of: $0) == "port" }) else { return lines }
            var lines = lines
            lines[portLine] = "port = \(local)"
            // The remote is spelled out only when it differs from the local port.
            if let remoteLine = lines.firstIndex(where: { key(of: $0) == "remote_port" }) {
                if remote == local { lines.remove(at: remoteLine) } else { lines[remoteLine] = "remote_port = \(remote)" }
            } else if remote != local {
                lines.insert("remote_port = \(remote)", at: portLine + 1)
            }
            // The moved flag lives right after the port lines.
            lines.removeAll { key(of: $0) == "moved" }
            if movedByApp, let after = lines.lastIndex(where: { key(of: $0) == "port" || key(of: $0) == "remote_port" }) {
                lines.insert("moved = true", at: after + 1)
            }
            return lines
        }
    }

    // MARK: [[host]] blocks

    static func addHost(_ host: AutoHost, to url: URL = defaultURL) throws {
        var text = "[[host]]\nname = \"\(escape(host.name))\"\nall_ports = true\n"
        if !host.excluded.isEmpty {
            text += "exclude = [\(host.excluded.sorted().map(String.init).joined(separator: ", "))]\n"
        }
        try appendBlock(text, to: url)
    }

    @discardableResult
    static func removeHost(_ name: String, from url: URL = defaultURL) throws -> Bool {
        try editBlock("host", in: url, matching: { $0["name"]?.string == name }) { _ in nil }
    }

    @discardableResult
    static func setExcluded(_ excluded: Set<Int>, forHost name: String, in url: URL = defaultURL) throws -> Bool {
        try editBlock("host", in: url, matching: { $0["name"]?.string == name }) { lines in
            replaceKey("exclude", in: lines, with: excluded.isEmpty ? nil : "exclude = [\(excluded.sorted().map(String.init).joined(separator: ", "))]")
        }
    }

    @discardableResult
    static func setOffset(_ offset: Int?, forHost name: String, in url: URL = defaultURL) throws -> Bool {
        try editBlock("host", in: url, matching: { $0["name"]?.string == name }) { lines in
            replaceKey("offset", in: lines, with: offset.map { "offset = \($0)" })
        }
    }

    // MARK: Block editing

    /// Append a block to the file, creating the file (with the template) if
    /// needed and keeping one blank line between blocks.
    private static func appendBlock(_ block: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? template
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty && !text.hasSuffix("\n\n") { text += "\n" }
        text += block
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Find the first `[[kind]]` block whose parsed table satisfies `matches`
    /// and replace its lines with `change(lines)`; nil removes the block and
    /// the blank lines directly above it. Every other line stays as it was.
    private static func editBlock(_ kind: String, in url: URL, matching matches: ([String: TOMLValue]) -> Bool, _ change: ([String]) -> [String]?) throws -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        for block in blocks(of: kind, in: lines) {
            guard let parsed = try? MiniTOML.parse(lines[block].joined(separator: "\n")),
                  let table = parsed[kind]?.tables?.first, matches(table) else { continue }
            if let replacement = change(Array(lines[block])) {
                lines.replaceSubrange(block, with: replacement)
            } else {
                var lower = block.lowerBound
                while lower > 0, lines[lower - 1].trimmingCharacters(in: .whitespaces).isEmpty { lower -= 1 }
                lines.removeSubrange(lower..<block.upperBound)
            }
            var result = lines.joined(separator: "\n")
            if !result.hasSuffix("\n") { result += "\n" }
            try result.write(to: url, atomically: true, encoding: .utf8)
            return true
        }
        return false
    }

    /// Line ranges of every `[[kind]]` block: its header up to the next header or the end.
    private static func blocks(of kind: String, in lines: [String]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }
            if let s = start { result.append(s..<index) }
            start = trimmed.hasPrefix("[[\(kind)]]") ? index : nil
        }
        if let s = start { result.append(s..<lines.count) }
        return result
    }

    /// Replace the line for `key` with `line`, or drop it when `line` is nil.
    /// A new line goes after the block's last non-blank line, so the gap
    /// before the next block stays where it is.
    private static func replaceKey(_ keyName: String, in lines: [String], with line: String?) -> [String] {
        var kept = lines.filter { key(of: $0) != keyName }
        if let line {
            let last = kept.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? kept.count - 1
            kept.insert(line, at: last + 1)
        }
        return kept
    }

    /// The key a `key = value` line sets; empty for anything else.
    private static func key(of line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix { $0 != "=" && $0 != " " })
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension Dictionary where Key == String, Value == TOMLValue {
    func isFavourite(_ spec: ForwardSpec) -> Bool {
        self["host"]?.string == spec.machine && self["port"]?.integer == spec.localPort
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
