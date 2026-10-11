import Darwin
import Foundation

/// Reads Host aliases out of ~/.ssh/config. Nothing else is parsed: ssh
/// resolves the alias itself when the master starts.
public enum SSHConfig {
    public static var defaultPath: String { NSHomeDirectory() + "/.ssh/config" }

    public static func hostAliases(configPath: String) -> [String] {
        var seen: [String] = []
        collect(path: configPath, into: &seen, depth: 0)
        return seen
    }

    /// Parse one file's text. `Include` lines are resolved relative to
    /// `baseDirectory` (ssh uses ~/.ssh for relative includes).
    public static func parse(_ text: String, baseDirectory: String, into aliases: inout [String], depth: Int) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // "Keyword value" or "Keyword=value"
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard let keyword = parts.first?.lowercased(), parts.count > 1 else { continue }
            let values = Array(parts.dropFirst())

            switch keyword {
            case "host":
                for alias in values where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                    if !aliases.contains(alias) { aliases.append(alias) }
                }
            case "include":
                guard depth < 8 else { continue }
                for pattern in values {
                    for path in expand(pattern, relativeTo: baseDirectory) {
                        collect(path: path, into: &aliases, depth: depth + 1)
                    }
                }
            default:
                continue
            }
        }
    }

    private static func collect(path: String, into aliases: inout [String], depth: Int) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let base = (path as NSString).deletingLastPathComponent
        parse(text, baseDirectory: base, into: &aliases, depth: depth)
    }

    /// Expand ~ and glob patterns the way ssh does for Include.
    static func expand(_ pattern: String, relativeTo baseDirectory: String) -> [String] {
        var expanded = pattern
        if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(expanded.dropFirst(1))
        } else if !expanded.hasPrefix("/") {
            expanded = NSHomeDirectory() + "/.ssh/" + expanded
        }
        var globResult = glob_t()
        defer { globfree(&globResult) }
        guard glob(expanded, GLOB_TILDE | GLOB_NOCHECK, nil, &globResult) == 0 else { return [] }
        var paths: [String] = []
        for index in 0..<Int(globResult.gl_matchc) {
            if let cString = globResult.gl_pathv[index] {
                paths.append(String(cString: cString))
            }
        }
        return paths.sorted()
    }
}
