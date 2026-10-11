import AppKit
import SwiftUI
import TunnelsCore

/// Development aid: with TUNNELS_SNAPSHOT=1 in the environment the app opens
/// the real menu panel at the top-left of the screen a few seconds after
/// launch, holds it, then quits, so `screencapture` can grab it.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested(statusItem: StatusItemController) {
        guard ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT"] != nil else { return }
        let delay = Double(ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_DELAY"] ?? "") ?? 6
        let hold = Double(ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_HOLD"] ?? "") ?? 4
        AppModel.shared.persistStateOnQuit = false
        if let host = ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_ALL"], !host.isEmpty {
            Task { @MainActor in AppModel.shared.enableAllPorts(host) }
        }
        if ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_TURN_ON"] != nil {
            Task { @MainActor in
                let model = AppModel.shared
                for forward in model.controller.forwards {
                    await model.controller.setForward(id: forward.id, on: true)
                }
            }
        }
        // TUNNELS_SNAPSHOT_SCRIPT="exclude:box-b:7777@8,off:box-b@12,on:box-b@15,all:box-b@16"
        if let script = ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_SCRIPT"] {
            for step in script.split(separator: ",") {
                let parts = step.split(separator: "@")
                guard parts.count == 2, let at = Double(parts[1]) else { continue }
                let fields = parts[0].split(separator: ":").map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    let model = AppModel.shared
                    DebugLog.log("script: \(step)")
                    switch fields.first {
                    case "exclude":
                        if fields.count == 3, let port = Int(fields[2]),
                           let forward = model.controller.forwards.first(where: { $0.spec.machine == fields[1] && $0.spec.localPort == port }) {
                            model.excludePort(forward)
                        } else { DebugLog.log("script: no such forward") }
                    case "off": model.setMachine(fields[1], on: false)
                    case "on": model.setMachine(fields[1], on: true)
                    case "all": model.enableAllPorts(fields[1])
                    case "closeall": model.closeAll()
                    default: break
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let model = AppModel.shared
            DebugLog.log("snapshot: forwards=\(model.controller.forwards.map { "\($0.spec.machine):\($0.spec.localPort) \($0.state) disc=\($0.isDiscovered)" }) machines=\(model.controller.machines) auto=\(model.controller.autoHosts) excluded=\(model.controller.autoExcluded) states=\(model.controller.machineStates)")
            for (alias, lines) in model.controller.logs { DebugLog.log("log \(alias):\n  " + lines.joined(separator: "\n  ")) }
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            if let edit = ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_EDITPORT"], let spec = QuickOpen.parse(edit) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { model.debugEditPort = spec }
            }
            statusItem.openForSnapshot(topLeft: NSPoint(x: 40, y: screen.height - 60))
            switch ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_PAGE"] {
            case "settings": model.menuPage = .settings
            case "logs": model.menuPage = .logs
            default: break
            }
            DebugLog.log("panel at 40,60 size \(Int(statusItem.panel?.frame.width ?? 0))x\(Int(statusItem.panel?.frame.height ?? 0))")
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { NSApp.terminate(nil) }
        }
    }
}
