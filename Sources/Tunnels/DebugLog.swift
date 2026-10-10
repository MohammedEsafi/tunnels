import Foundation

/// stderr logging, only when TUNNELS_DEBUG is set. Silent in normal use.
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["TUNNELS_DEBUG"] != nil
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[tunnels] " + message() + "\n").utf8))
    }
}
