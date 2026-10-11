import Foundation

/// A machine you can type as the host part of host:port, from any source.
public struct HostEntry: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable { case sshConfig, tailscale }

    public var name: String
    public var source: Source
    /// Only Tailscale reports liveness; ssh config hosts are nil.
    public var online: Bool?

    public var id: String { "\(source):\(name)" }

    public init(name: String, source: Source, online: Bool? = nil) {
        self.name = name
        self.source = source
        self.online = online
    }
}

/// Peers from `tailscale status --json`. Names resolve through MagicDNS, so
/// `ssh <hostname>` works without an ssh config entry.
public enum TailscaleHosts {
    /// Where the CLI usually lives: the Mac App Store app, Homebrew, Nix.
    public static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/run/current-system/sw/bin/tailscale",
        "/etc/profiles/per-user/\(NSUserName())/bin/tailscale",
    ]

    public static func executable() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func fetch(runner: any ProcessRunning) async -> [HostEntry] {
        guard let path = executable(),
            let result = try? await runner.run(path, arguments: ["status", "--json"], timeout: 5),
            result.succeeded
        else { return [] }
        return parse(result.stdout)
    }

    public static func parse(_ json: String) -> [HostEntry] {
        guard let data = json.data(using: .utf8),
            let status = try? JSONDecoder().decode(Status.self, from: data)
        else { return [] }
        let peers = status.peer?.values ?? [:].values
        return
            peers
            .compactMap { peer -> HostEntry? in
                let name = peer.hostName.lowercased()
                guard !name.isEmpty else { return nil }
                return HostEntry(name: name, source: .tailscale, online: peer.online ?? false)
            }
            .sorted { a, b in
                if a.online != b.online { return a.online == true }
                return a.name < b.name
            }
    }

    private struct Status: Decodable {
        let peer: [String: Peer]?
        enum CodingKeys: String, CodingKey { case peer = "Peer" }
    }

    private struct Peer: Decodable {
        let hostName: String
        let online: Bool?
        enum CodingKeys: String, CodingKey {
            case hostName = "HostName"
            case online = "Online"
        }
    }
}
