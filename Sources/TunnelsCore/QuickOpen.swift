import Foundation

public enum Suggestion: Equatable, Hashable, Identifiable {
    case favourite(Favourite)
    case host(HostEntry)
    case spec(ForwardSpec)

    public var id: String {
        switch self {
        case .favourite(let f): return "fav:" + f.spec.sshArgument + "@" + f.spec.machine
        case .host(let h): return "host:" + h.id
        case .spec(let s): return "spec:" + s.sshArgument + "@" + s.machine
        }
    }
}

/// Parsing for the quick-open field and ranking of suggestions.
public enum QuickOpen {
    /// Accepted forms:
    ///   host:port
    ///   host:local:remote
    ///   host:local:remoteHost:remote
    public static func parse(_ input: String) -> ForwardSpec? {
        let text = input.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 4 else { return nil }
        let host = parts[0].trimmingCharacters(in: .whitespaces)
        guard isHost(host) else { return nil }
        guard let local = port(parts[1]) else { return nil }
        switch parts.count {
        case 2:
            return ForwardSpec(machine: host, localPort: local)
        case 3:
            guard let remote = port(parts[2]) else { return nil }
            return ForwardSpec(machine: host, localPort: local, remotePort: remote)
        default:
            let remoteHost = parts[2].trimmingCharacters(in: .whitespaces)
            guard isHost(remoteHost), let remote = port(parts[3]) else { return nil }
            return ForwardSpec(machine: host, localPort: local, remoteHost: remoteHost, remotePort: remote)
        }
    }

    /// With empty input: every favourite then every host, so a focused empty
    /// field doubles as a list of what you can open.
    public static func suggestions(for input: String, favourites: [Favourite], hosts: [HostEntry], limit: Int = 6) -> [Suggestion] {
        let text = input.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            var all: [Suggestion] = favourites.map { .favourite($0) }
            for host in hosts where !all.contains(.host(host)) { all.append(.host(host)) }
            return Array(all.prefix(limit))
        }
        var result: [Suggestion] = []

        if let spec = parse(text) {
            result.append(.spec(spec))
        }

        let needle = text.lowercased()
        let hostPart = text.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? needle

        let matchingFavourites = favourites.filter {
            $0.name.lowercased().contains(needle) || $0.spec.machine.lowercased().contains(needle) || $0.spec.machine.lowercased().hasPrefix(hostPart)
        }
        let ranked = matchingFavourites.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(needle) || a.spec.machine.lowercased().hasPrefix(needle)
            let bPrefix = b.name.lowercased().hasPrefix(needle) || b.spec.machine.lowercased().hasPrefix(needle)
            if aPrefix != bPrefix { return aPrefix }
            return a.name < b.name
        }
        for favourite in ranked { result.append(.favourite(favourite)) }

        if !text.contains(":") {
            let matchingHosts = hosts.filter { $0.name.lowercased().contains(needle) }
                .sorted { a, b in
                    let aPrefix = a.name.lowercased().hasPrefix(needle)
                    let bPrefix = b.name.lowercased().hasPrefix(needle)
                    if aPrefix != bPrefix { return aPrefix }
                    return a.name < b.name
                }
            for host in matchingHosts where !result.contains(.host(host)) {
                result.append(.host(host))
            }
        }

        return Array(result.prefix(limit))
    }

    private static func port(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }

    private static func isHost(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._@"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
