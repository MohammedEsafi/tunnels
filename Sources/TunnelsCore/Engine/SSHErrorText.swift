import Foundation

public enum SSHError: Error, LocalizedError, Equatable {
    case masterExited(String)
    case timeout
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .masterExited(let text): return SSHErrorText.humanize(text)
        case .timeout: return "Timed out waiting for the connection"
        case .commandFailed(let text): return SSHErrorText.humanize(text)
        }
    }
}

/// Turns ssh's stderr into one short line for the UI.
public enum SSHErrorText {
    /// Two or three words for a menu row, from a `humanize` result.
    public static func short(_ reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("no usable key") { return "No key in agent" }
        if lower.contains("unknown host") { return "Unknown host" }
        if lower.contains("port in use") { return "Port in use" }
        if lower.contains("unreachable") { return "Unreachable" }
        if lower.contains("timed out") { return "Timed out" }
        if lower.contains("host key") { return "Host key failed" }
        if lower.contains("refused the forward") { return "Remote refused" }
        if lower.contains("connection is gone") { return "Disconnected" }
        if lower.contains("exited with status") { return "ssh exited" }
        let words = reason.split(separator: " ")
        return words.count <= 3 ? reason : words.prefix(3).joined(separator: " ") + "…"
    }

    public static func humanize(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("permission denied") {
            return "No usable key in the agent. Run ssh-add."
        }
        if lower.contains("could not resolve hostname") {
            return "Unknown host"
        }
        // The remote wording contains the local one, so it goes first.
        if lower.contains("remote port forwarding failed") {
            return "Remote end refused the forward"
        }
        if lower.contains("address already in use") || lower.contains("port forwarding failed") {
            return "Local port in use"
        }
        if lower.contains("connection refused") || lower.contains("no route to host") {
            return "Host unreachable"
        }
        if lower.contains("connection timed out") || lower.contains("operation timed out") {
            return "Connection timed out"
        }
        if lower.contains("host key verification failed") {
            return "Host key verification failed"
        }
        if lower.contains("forwarding failed") {
            return "Remote end refused the forward"
        }
        if lower.contains("control socket") && lower.contains("no such file") {
            return "Connection is gone"
        }
        if text.isEmpty { return "ssh failed" }
        // Last non-empty line, without the "ssh: " prefix.
        let last = text.split(separator: "\n").last.map(String.init) ?? text
        let cleaned = last.replacingOccurrences(of: "ssh: ", with: "")
        return cleaned.isEmpty ? "ssh failed" : cleaned
    }
}
