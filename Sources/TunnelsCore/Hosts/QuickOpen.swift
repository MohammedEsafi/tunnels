import Foundation

public enum Suggestion: Equatable, Hashable, Identifiable {
    case favourite(Favourite)
    case host(HostEntry)
    case allPorts(String)
    case spec(ForwardSpec)

    public var id: String {
        switch self {
        case .favourite(let f): return "fav:" + f.spec.sshArgument + "@" + f.spec.machine
        case .host(let h): return "host:" + h.id
        case .allPorts(let h): return "all:" + h
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

    /// With empty input: the machines you can start from. Remembered forwards
    /// are already listed in the menu, so they only appear once you type.
    public static func suggestions(for input: String, favourites: [Favourite], hosts: [HostEntry], limit: Int = 8) -> [Suggestion] {
        let text = input.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            return Array(hosts.map { Suggestion.host($0) }.prefix(limit))
        }
        var result: [Suggestion] = []

        if let spec = parse(text) {
            result.append(.spec(spec))
        }

        let needle = text.lowercased()

        // Machines first: a typed name is most likely a machine.
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
            // Exactly one host named: offer every port on it, right under it.
            if let exact = matchingHosts.first(where: { $0.name.lowercased() == needle }) {
                result.insert(
                    .allPorts(exact.name), at: min(result.firstIndex(of: .host(exact)).map { $0 + 1 } ?? result.count, result.count))
            } else if matchingHosts.isEmpty, isHost(text), !favourites.contains(where: { $0.name.lowercased().contains(needle) }) {
                // A name we do not know, typed in full: ssh may still resolve it.
                result.append(.allPorts(text))
            }
        }

        // Then remembered forwards, matched by their own name only.
        let matchingFavourites = favourites.filter { $0.name.lowercased().contains(needle) }
        let ranked = matchingFavourites.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(needle)
            let bPrefix = b.name.lowercased().hasPrefix(needle)
            if aPrefix != bPrefix { return aPrefix }
            return a.name < b.name
        }
        for favourite in ranked { result.append(.favourite(favourite)) }

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
