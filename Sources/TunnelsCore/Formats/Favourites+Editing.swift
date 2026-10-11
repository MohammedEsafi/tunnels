import Foundation

// MARK: Writing

extension Favourites {
    /// One [[favourite]] block. Only non-default keys are written.
    public static func serialize(_ favourite: Favourite) -> String {
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
    public static func add(_ favourite: Favourite, to url: URL = defaultURL) throws {
        try appendBlock(serialize(favourite), to: url)
    }

    /// Remove the [[favourite]] block whose host and port match. Other blocks
    /// and their comments are left exactly as they were.
    @discardableResult
    public static func remove(_ spec: ForwardSpec, from url: URL = defaultURL) throws -> Bool {
        try editBlock("favourite", in: url, matching: { $0.isFavourite(spec) }) { _ in nil }
    }

    /// Change the name of the [[favourite]] block matching host and port,
    /// touching no other line.
    @discardableResult
    public static func rename(_ spec: ForwardSpec, to name: String, in url: URL = defaultURL) throws -> Bool {
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
    public static func changeLocalPort(_ spec: ForwardSpec, to newPort: Int, movedByApp: Bool = false, in url: URL = defaultURL) throws
        -> Bool
    {
        try changePorts(spec, local: newPort, remote: spec.remotePort, movedByApp: movedByApp, in: url)
    }

    /// Change the local and remote ports of the [[favourite]] block matching
    /// host and port. `remote_port` is written only when it differs from `port`.
    @discardableResult
    public static func changePorts(_ spec: ForwardSpec, local: Int, remote: Int, movedByApp: Bool = false, in url: URL = defaultURL) throws
        -> Bool
    {
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

    public static func addHost(_ host: AutoHost, to url: URL = defaultURL) throws {
        var text = "[[host]]\nname = \"\(escape(host.name))\"\nall_ports = true\n"
        if !host.excluded.isEmpty {
            text += "exclude = [\(host.excluded.sorted().map(String.init).joined(separator: ", "))]\n"
        }
        try appendBlock(text, to: url)
    }

    @discardableResult
    public static func removeHost(_ name: String, from url: URL = defaultURL) throws -> Bool {
        try editBlock("host", in: url, matching: { $0["name"]?.string == name }) { _ in nil }
    }

    @discardableResult
    public static func setExcluded(_ excluded: Set<Int>, forHost name: String, in url: URL = defaultURL) throws -> Bool {
        try editBlock("host", in: url, matching: { $0["name"]?.string == name }) { lines in
            replaceKey(
                "exclude", in: lines,
                with: excluded.isEmpty ? nil : "exclude = [\(excluded.sorted().map(String.init).joined(separator: ", "))]")
        }
    }

    @discardableResult
    public static func setOffset(_ offset: Int?, forHost name: String, in url: URL = defaultURL) throws -> Bool {
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
    private static func editBlock(
        _ kind: String, in url: URL, matching matches: ([String: TOMLValue]) -> Bool, _ change: ([String]) -> [String]?
    ) throws -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        for block in blocks(of: kind, in: lines) {
            guard let parsed = try? MiniTOML.parse(lines[block].joined(separator: "\n")),
                let table = parsed[kind]?.tables?.first, matches(table)
            else { continue }
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

extension Dictionary where Key == String, Value == TOMLValue {
    fileprivate func isFavourite(_ spec: ForwardSpec) -> Bool {
        self["host"]?.string == spec.machine && self["port"]?.integer == spec.localPort
    }
}
