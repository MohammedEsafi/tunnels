import Foundation

/// Finds TCP listeners on a machine, for all-ports mode.
public enum PortDiscovery {
    /// `ss` on modern Linux, the kernel's own /proc/net/tcp tables when it is
    /// not installed (containers), and `netstat -an` everywhere else, macOS
    /// included. Not `netstat -tln`: a Mac accepts those flags but prints only
    /// established connections, exits 0, and the chain would stop there.
    public static let command =
        "ss -ltnH 2>/dev/null || cat /proc/net/tcp /proc/net/tcp6 2>/dev/null || netstat -an 2>/dev/null"

    /// Ports a service would be deliberately started on: 1024 up to the start
    /// of Linux's ephemeral range (32768), minus sshd's own. Loopback and
    /// wildcard binds alike, so localhost:<port> means the same on both ends.
    static func wanted(_ port: Int) -> Bool {
        port >= 1024 && port < 32768 && port != 22
    }

    public static func parse(_ output: String) -> Set<Int> {
        listeners(output).filter(wanted)
    }

    /// Every TCP listener, unfiltered. Used to tell whether a pinned
    /// forward's remote port has anything behind it.
    public static func listeners(_ output: String) -> Set<Int> {
        var ports: Set<Int> = []
        for line in output.split(separator: "\n") {
            if let port = procNetPort(line) {
                ports.insert(port)
                continue
            }
            // ss and netstat both print LISTEN for a listening TCP socket; every
            // other state, and UDP (which has no state column), is not one.
            guard line.lowercased().contains("listen") else { continue }
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard let colon = token.lastIndex(where: { $0 == ":" || $0 == "." }),
                    let port = Int(token[token.index(after: colon)...])
                else { continue }
                let host = token[..<colon]
                guard !host.isEmpty else { continue }
                guard
                    host.allSatisfy({
                        $0.isNumber || $0 == "." || $0 == ":" || $0 == "[" || $0 == "]" || $0 == "*" || $0 == "%" || $0.isLetter
                    })
                else { continue }
                ports.insert(port)
                break  // first address-like token on the line is the local one
            }
        }
        return ports
    }

    /// One line of /proc/net/tcp or tcp6:
    ///   sl  local_address rem_address   st ...
    ///    0: 0100007F:0BB8 00000000:0000 0A ...
    /// Returns the port when the socket is listening (st 0A).
    static func procNetPort(_ line: Substring) -> Int? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4, fields[0].hasSuffix(":"), fields[3] == "0A" else { return nil }
        let local = fields[1].split(separator: ":")
        guard local.count == 2, local[0].count == 8 || local[0].count == 32, local[1].count == 4,
            let port = Int(local[1], radix: 16)
        else { return nil }
        return port
    }
}
