import AppKit
import ServiceManagement
import TunnelsCore

/// One-shot actions from the menu: clipboard, browser, files, login item.
extension AppModel {
    func openInBrowser(_ spec: ForwardSpec) {
        if let url = URL(string: "http://localhost:\(spec.localPort)/") { NSWorkspace.shared.open(url) }
    }

    func showLog(_ alias: String) {
        logSelection = alias
        menuPage = .logs
    }

    /// The plain ssh equivalent of this machine's forwards, for pasting elsewhere.
    func copySSHCommand(_ alias: String) {
        let on = controller.forwards(on: alias).filter(\.desiredOn)
        var parts = ["ssh", "-N"]
        for forward in on { parts += ["-L", forward.spec.sshArgument] }
        parts.append(alias)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(parts.joined(separator: " "), forType: .string)
    }

    /// "localhost:<port>" to the clipboard, the usual next step after opening.
    func copyAddress(of spec: ForwardSpec) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("localhost:\(spec.localPort)", forType: .string)
    }

    /// Open ~/.ssh/config in the default editor, creating it if needed.
    func openSSHConfig() {
        let path = sshConfigPath
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: path, contents: Data("# Host example\n#   HostName 10.0.0.5\n#   User you\n".utf8), attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
    /// "45 seconds", "3 minutes", "2 hours".
    static func describe(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return "\(s) seconds" }
        let m = Int((seconds / 60).rounded())
        if m < 90 { return "\(m) minutes" }
        let h = Int((seconds / 3600).rounded())
        return h == 1 ? "1 hour" : "\(h) hours"
    }
}
