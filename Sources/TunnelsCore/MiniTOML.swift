import Foundation

/// A deliberately small TOML reader: enough for a favourites file, with no
/// dependency. Supports comments, `[table]`, `[[array of tables]]`,
/// dotted-free keys, strings ("basic" and 'literal'), integers, floats,
/// booleans and flat arrays of those. Anything else is a parse error.
public enum TOMLValue: Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var integer: Int? { if case .integer(let i) = self { return i } else { return nil } }
    public var boolean: Bool? { if case .boolean(let b) = self { return b } else { return nil } }
    public var tables: [[String: TOMLValue]]? {
        if case .array(let items) = self {
            let tables = items.compactMap { item -> [String: TOMLValue]? in
                if case .table(let t) = item { return t } else { return nil }
            }
            return tables.count == items.count ? tables : nil
        }
        return nil
    }
}

public struct TOMLError: Error, Equatable, LocalizedError {
    public let line: Int
    public let message: String
    public var errorDescription: String? { "line \(line): \(message)" }
}

public enum MiniTOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        // Where new keys go: a path of table names, and for array tables the index.
        var currentPath: [String] = []
        var currentIsArrayElement = false

        let lines = text.components(separatedBy: .newlines)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else { throw TOMLError(line: lineNumber, message: "unterminated [[table]] header") }
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                try validateKey(name, line: lineNumber)
                currentPath = [name]
                currentIsArrayElement = true
                var items = root[name]?.arrayItems ?? []
                items.append(.table([:]))
                root[name] = .array(items)
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw TOMLError(line: lineNumber, message: "unterminated [table] header") }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                try validateKey(name, line: lineNumber)
                currentPath = [name]
                currentIsArrayElement = false
                if root[name] == nil { root[name] = .table([:]) }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                throw TOMLError(line: lineNumber, message: "expected key = value")
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            try validateKey(key, line: lineNumber)
            let value = try parseValue(rawValue, line: lineNumber)

            if currentPath.isEmpty {
                root[key] = value
            } else if currentIsArrayElement {
                let name = currentPath[0]
                var items = root[name]?.arrayItems ?? []
                guard case .table(var table) = items[items.count - 1] else { continue }
                table[key] = value
                items[items.count - 1] = .table(table)
                root[name] = .array(items)
            } else {
                let name = currentPath[0]
                guard case .table(var table) = root[name] ?? .table([:]) else {
                    throw TOMLError(line: lineNumber, message: "\(name) is not a table")
                }
                table[key] = value
                root[name] = .table(table)
            }
        }
        return root
    }

    private static func validateKey(_ key: String, line: Int) throws {
        guard !key.isEmpty else { throw TOMLError(line: line, message: "empty key") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw TOMLError(line: line, message: "unsupported key \"\(key)\" (use letters, digits, _ or -)")
        }
    }

    static func parseValue(_ raw: String, line: Int) throws -> TOMLValue {
        guard !raw.isEmpty else { throw TOMLError(line: line, message: "missing value") }
        if raw.hasPrefix("\"") {
            guard raw.count >= 2, raw.hasSuffix("\"") else { throw TOMLError(line: line, message: "unterminated string") }
            return .string(try unescape(String(raw.dropFirst().dropLast()), line: line))
        }
        if raw.hasPrefix("'") {
            guard raw.count >= 2, raw.hasSuffix("'") else { throw TOMLError(line: line, message: "unterminated string") }
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else { throw TOMLError(line: line, message: "unterminated array") }
            let inner = String(raw.dropFirst().dropLast())
            let parts = splitTopLevel(inner)
            return .array(try parts.map { try parseValue($0.trimmingCharacters(in: .whitespaces), line: line) })
        }
        let numeric = raw.replacingOccurrences(of: "_", with: "")
        if let int = Int(numeric) { return .integer(int) }
        if let double = Double(numeric) { return .double(double) }
        throw TOMLError(line: line, message: "cannot read value \(raw)")
    }

    private static func unescape(_ text: String, line: Int) throws -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else { result.append(char); continue }
            guard let next = iterator.next() else { throw TOMLError(line: line, message: "dangling backslash") }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default: throw TOMLError(line: line, message: "unsupported escape \\\(next)")
            }
        }
        return result
    }

    /// Remove a trailing comment, ignoring # inside quotes.
    static func stripComment(_ line: String) -> String {
        var inDouble = false
        var inSingle = false
        var result = ""
        var previous: Character = " "
        for char in line {
            if char == "\"" && !inSingle && previous != "\\" { inDouble.toggle() }
            if char == "'" && !inDouble { inSingle.toggle() }
            if char == "#" && !inDouble && !inSingle { break }
            result.append(char)
            previous = char
        }
        return result
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        for char in text {
            if char == "\"" && !inSingle { inDouble.toggle() }
            if char == "'" && !inDouble { inSingle.toggle() }
            if char == "," && !inDouble && !inSingle {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }
}

private extension TOMLValue {
    var arrayItems: [TOMLValue]? {
        if case .array(let items) = self { return items } else { return nil }
    }
}
