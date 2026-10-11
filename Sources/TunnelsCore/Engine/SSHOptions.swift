import Foundation

/// How the core runs ssh. The app decides these once; the library never
/// reads the environment or picks paths on its own.
public struct SSHOptions: Sendable {
    public var sshPath = "/usr/bin/ssh"
    /// An alternative client config (`-F`); nil uses ssh's own default.
    public var configPath: String?
    /// Where the ControlMaster sockets live; created 0700.
    public var socketDirectory: URL
    /// Options passed to every master. The defaults keep the connection in
    /// batch mode, fail fast on a bad forward, and notice a dead peer.
    public var masterOptions = SSHOptions.defaultMasterOptions

    public init(socketDirectory: URL, configPath: String? = nil) {
        self.socketDirectory = socketDirectory
        self.configPath = configPath
    }

    public static let defaultMasterOptions: [String] = [
        "-o", "ControlPersist=no",
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",
    ]

    var configArguments: [String] { configPath.map { ["-F", $0] } ?? [] }
}
