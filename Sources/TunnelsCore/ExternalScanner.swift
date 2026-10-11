import Foundation

/// Finds `ssh -L` processes the app does not own, so they can be shown and
/// stopped. Display only: nothing here is used to drive ssh.
public enum ExternalScanner {
    public static let psArguments = ["-axo", "pid=,uid=,command="]

    public static func scan(runner: any ProcessRunning, currentUID: uid_t = getuid()) async -> [ExternalForward] {
        guard let result = try? await runner.run("/bin/ps", arguments: psArguments, timeout: 10), result.succeeded else {
            return []
        }
        return parse(result.stdout, currentUID: currentUID)
    }

    /// Parse `ps -axo pid=,uid=,command=` output. Only processes owned by
    /// `currentUID` are returned, since those are the only ones we can stop.
    public static func parse(_ output: String, currentUID: uid_t) -> [ExternalForward] {
        var found: [ExternalForward] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let columns = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count == 3,
                  let pid = Int32(columns[0]),
                  let uid = UInt32(columns[1]),
                  uid == currentUID else { continue }
            let command = String(columns[2])
            found.append(contentsOf: forwards(inCommand: command, pid: pid))
        }
        return found
    }

    /// Pull every -L spec and the target alias out of one ssh command line.
    static func forwards(inCommand command: String, pid: Int32) -> [ExternalForward] {
        let tokens = tokenize(command)
        guard let first = tokens.first else { return [] }
        let executable = (first as NSString).lastPathComponent
        guard executable == "ssh" else { return [] }
        // Control commands (-O forward) are short-lived helpers, not forwards.
        if tokens.contains("-O") { return [] }

        var specs: [String] = []
        var target: String?
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                if index < tokens.count { target = tokens[index] }
                break
            }
            if token.hasPrefix("-") && token.count > 1 {
                let flag = String(token.prefix(2))
                if flag == "-L" {
                    if token.count > 2 {
                        specs.append(String(token.dropFirst(2)))
                    } else if index + 1 < tokens.count {
                        index += 1
                        specs.append(tokens[index])
                    }
                } else if optionsWithValue.contains(flag) {
                    if token.count == 2 { index += 1 }
                }
                index += 1
                continue
            }
            // ps prints arguments without their quotes, so an option value with
            // spaces ("ProxyCommand=sleep 600") leaks fragments here. Skip anything
            // that cannot be a host, and take the first plausible one.
            if looksLikeHost(token) {
                target = token
                break
            }
            index += 1
        }

        guard !specs.isEmpty else { return [] }
        var alias = target ?? "?"
        if alias.hasPrefix("ssh://") { alias = String(alias.dropFirst(6)) }
        if let at = alias.lastIndex(of: "@") { alias = String(alias[alias.index(after: at)...]) }

        return specs.compactMap { spec -> ExternalForward? in
            guard let forward = parseForwardSpec(spec, machine: alias) else { return nil }
            return ExternalForward(pid: pid, spec: forward, command: command)
        }
    }

    /// Host-ish: letters allowed in hostnames or user@host, and not purely numeric.
    static func looksLikeHost(_ token: String) -> Bool {
        var text = token
        if text.hasPrefix("ssh://") { text = String(text.dropFirst(6)) }
        guard !text.isEmpty, Int(text) == nil else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._@:[]"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) } && text.rangeOfCharacter(from: .letters) != nil
    }

    /// ssh options that take a value, so the value is not mistaken for the host.
    static let optionsWithValue: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l",
        "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
    ]

    /// [bind_address:]port:host:hostport
    static func parseForwardSpec(_ text: String, machine: String) -> ForwardSpec? {
        let parts = text.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let local = Int(parts[0]), let remote = Int(parts[2]) else { return nil }
            return ForwardSpec(machine: machine, localPort: local, remoteHost: parts[1], remotePort: remote)
        case 4:
            guard let local = Int(parts[1]), let remote = Int(parts[3]) else { return nil }
            return ForwardSpec(machine: machine, localPort: local, remoteHost: parts[2], remotePort: remote)
        default:
            return nil
        }
    }

    /// Split on spaces, honouring simple quotes.
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for char in command {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == " " {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// SIGTERM, only ever sent to a pid the scan found under the current user.
    @discardableResult
    public static func stop(pid: Int32) -> Bool {
        kill(pid, SIGTERM) == 0
    }

    /// ssh masters started by an earlier run of the app (they use our socket
    /// directory) that are no longer children of anything of ours. A crash or
    /// a force quit leaves them behind, still holding their local ports.
    public static func staleMasters(runner: any ProcessRunning, socketDirectory: URL, currentUID: uid_t = getuid()) async -> [Int32] {
        guard let result = try? await runner.run("/bin/ps", arguments: ["-axo", "pid=,uid=,ppid=,command="], timeout: 10), result.succeeded else {
            return []
        }
        return staleMasters(in: result.stdout, socketDirectory: socketDirectory, currentUID: currentUID, ownPID: getpid())
    }

    static func staleMasters(in output: String, socketDirectory: URL, currentUID: uid_t, ownPID: Int32) -> [Int32] {
        let marker = " -S " + socketDirectory.path + "/"
        var found: [Int32] = []
        for line in output.split(separator: "\n") {
            let columns = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard columns.count == 4,
                  let pid = Int32(columns[0]),
                  let uid = UInt32(columns[1]), uid == currentUID,
                  let ppid = Int32(columns[2]) else { continue }
            let command = String(columns[3])
            guard command.contains(" -N -M"), command.contains(marker), ppid != ownPID else { continue }
            found.append(pid)
        }
        return found
    }
}
