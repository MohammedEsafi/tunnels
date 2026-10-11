import Foundation

/// A machine is a Host alias from ~/.ssh/config. The app never stores
/// hostnames, users or keys; ssh resolves the alias itself.
public struct Machine: Identifiable, Hashable, Sendable {
    public var alias: String
    public var id: String { alias }

    public init(alias: String) {
        self.alias = alias
    }
}

/// Connection state of the per-machine master connection.
public enum MachineState: Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    /// Dropped and retrying. `attempt` is the next attempt number, starting at 1.
    case dropped(attempt: Int)
    /// Gave up after the retry budget, or hit a hard error such as a missing key.
    case failed(reason: String)
}

/// One local port forward: 127.0.0.1:localPort -> remoteHost:remotePort via `machine`.
public struct ForwardSpec: Hashable, Sendable, Codable {
    public var machine: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(machine: String, localPort: Int, remoteHost: String = "localhost", remotePort: Int? = nil) {
        self.machine = machine
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort ?? localPort
    }

    /// The exact argument ssh expects after -L. The listener always binds loopback.
    public var sshArgument: String {
        "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
    }

    /// Short display form: "5432" or "15432 → 5432".
    public var portLabel: String {
        localPort == remotePort ? "\(localPort)" : "\(localPort) → \(remotePort)"
    }
}

/// What the user asked for (the switch) versus what ssh reports.
public enum ForwardState: Hashable, Sendable {
    case off
    case pending
    case active
    case dropped
    case error(String)
}

public struct Forward: Identifiable, Hashable, Sendable {
    public var id: String { spec.sshArgument + "@" + spec.machine }
    public var spec: ForwardSpec
    public var name: String
    public var isFavourite: Bool
    /// Found by all-ports discovery; it exists while the remote listens.
    public var isDiscovered: Bool
    public var desiredOn: Bool
    public var state: ForwardState

    public init(spec: ForwardSpec, name: String, isFavourite: Bool, isDiscovered: Bool = false, desiredOn: Bool = false, state: ForwardState = .off) {
        self.spec = spec
        self.name = name
        self.isFavourite = isFavourite
        self.isDiscovered = isDiscovered
        self.desiredOn = desiredOn
        self.state = state
    }
}

/// A forward found in an ssh process the app does not own.
public struct ExternalForward: Identifiable, Hashable, Sendable {
    public var pid: Int32
    public var spec: ForwardSpec
    public var command: String
    public var id: String { "\(pid):\(spec.sshArgument)" }

    public init(pid: Int32, spec: ForwardSpec, command: String) {
        self.pid = pid
        self.spec = spec
        self.command = command
    }
}
