import Foundation

public struct Favourite: Equatable, Hashable, Sendable {
    public var name: String
    public var spec: ForwardSpec

    public init(name: String, spec: ForwardSpec) {
        self.name = name
        self.spec = spec
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
            result.append(Favourite(name: (name?.isEmpty == false ? name! : "\(remotePort)"), spec: spec))
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? template
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty && !text.hasSuffix("\n\n") { text += "\n" }
        text += serialize(favourite)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove the [[favourite]] block whose host and port match. Other blocks
    /// and their comments are left exactly as they were.
    @discardableResult
    static func remove(_ spec: ForwardSpec, from url: URL = defaultURL) throws -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n")
        // Block = a [[favourite]] header line up to the next header or end.
        var blocks: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                if let s = start { blocks.append(s..<index) }
                start = trimmed.hasPrefix("[[favourite]]") ? index : nil
            }
        }
        if let s = start { blocks.append(s..<lines.count) }

        for block in blocks.reversed() {
            let blockText = lines[block].joined(separator: "\n")
            guard let parsed = try? MiniTOML.parse(blockText),
                  let table = parsed["favourite"]?.tables?.first,
                  table["host"]?.string == spec.machine,
                  table["port"]?.integer == spec.localPort else { continue }
            var kept = lines
            // Also drop blank lines directly above the block so no gap grows.
            var lower = block.lowerBound
            while lower > 0, kept[lower - 1].trimmingCharacters(in: .whitespaces).isEmpty { lower -= 1 }
            kept.removeSubrange(lower..<block.upperBound)
            var result = kept.joined(separator: "\n")
            if !result.hasSuffix("\n") { result += "\n" }
            try result.write(to: url, atomically: true, encoding: .utf8)
            return true
        }
        return false
    }

    /// Change the name of the [[favourite]] block matching host and port,
    /// touching no other line.
    @discardableResult
    static func rename(_ spec: ForwardSpec, to name: String, in url: URL = defaultURL) throws -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        var blocks: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if let s = start { blocks.append(s..<index) }
                start = trimmed.hasPrefix("[[favourite]]") ? index : nil
            }
        }
        if let s = start { blocks.append(s..<lines.count) }

        for block in blocks {
            let blockText = lines[block].joined(separator: "\n")
            guard let parsed = try? MiniTOML.parse(blockText),
                  let table = parsed["favourite"]?.tables?.first,
                  table["host"]?.string == spec.machine,
                  table["port"]?.integer == spec.localPort else { continue }
            let nameLine = "name = \"\(escape(name))\""
            if let existing = lines[block].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name") }) {
                lines[existing] = nameLine
            } else {
                lines.insert(nameLine, at: block.lowerBound + 1)
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        }
        return false
    }

    // MARK: [[host]] blocks

    public static func addHost(_ host: AutoHost, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? template
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty && !text.hasSuffix("\n\n") { text += "\n" }
        text += "[[host]]\nname = \"\(escape(host.name))\"\nall_ports = true\n"
        if !host.excluded.isEmpty {
            text += "exclude = [\(host.excluded.sorted().map(String.init).joined(separator: ", "))]\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public static func removeHost(_ name: String, from url: URL = defaultURL) throws -> Bool {
        try editHostBlock(name, in: url) { _ in nil }
    }

    @discardableResult
    public static func setExcluded(_ excluded: Set<Int>, forHost name: String, in url: URL = defaultURL) throws -> Bool {
        try editHostBlock(name, in: url) { lines in
            var kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("exclude") }
            if !excluded.isEmpty {
                // Insert after the last non-blank line so trailing blank lines
                // (the gap before the next block) stay where they are.
                let last = kept.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? kept.count - 1
                kept.insert("exclude = [\(excluded.sorted().map(String.init).joined(separator: ", "))]", at: last + 1)
            }
            return kept
        }
    }

    @discardableResult
    public static func setOffset(_ offset: Int?, forHost name: String, in url: URL = defaultURL) throws -> Bool {
        try editHostBlock(name, in: url) { lines in
            var kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("offset") }
            if let offset {
                let last = kept.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? kept.count - 1
                kept.insert("offset = \(offset)", at: last + 1)
            }
            return kept
        }
    }

    /// Find the [[host]] block with this name and replace its lines (nil removes it).
    private static func editHostBlock(_ name: String, in url: URL, _ change: ([String]) -> [String]?) throws -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        var blocks: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if let s = start { blocks.append(s..<index) }
                start = trimmed.hasPrefix("[[host]]") ? index : nil
            }
        }
        if let s = start { blocks.append(s..<lines.count) }
        for block in blocks.reversed() {
            let blockText = lines[block].joined(separator: "\n")
            guard let parsed = try? MiniTOML.parse(blockText),
                  let table = parsed["host"]?.tables?.first,
                  table["name"]?.string == name else { continue }
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

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
