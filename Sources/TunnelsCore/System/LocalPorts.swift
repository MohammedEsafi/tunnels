import Darwin
import Foundation

/// Whether something on this Mac already listens on a TCP port.
///
/// ssh binds its `-L` listeners with SO_REUSEADDR, and on macOS such a bind
/// on 127.0.0.1 succeeds beside an existing listener on 0.0.0.0, after
/// which connections to localhost go to the newer socket. A discovered port
/// is checked here first, so a remote machine cannot take over a port a
/// local program already serves.
public enum LocalPorts {
    public static func isTaken(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        // No SO_REUSEADDR: the wildcard bind then fails against a listener on
        // any address for this port.
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && errno == EADDRINUSE
    }
}
