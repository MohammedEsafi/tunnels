import AppKit
import SwiftUI

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
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let model = AppModel.shared
            DebugLog.log("snapshot: forwards=\(model.controller.forwards.count) machines=\(model.controller.machines) external=\(model.external.count) states=\(model.controller.machineStates)")
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            statusItem.openForSnapshot(topLeft: NSPoint(x: 40, y: screen.height - 60))
            switch ProcessInfo.processInfo.environment["TUNNELS_SNAPSHOT_PAGE"] {
            case "settings": model.menuPage = .settings
            case "pinned": model.menuPage = .pinned
            case "logs": model.menuPage = .logs
            default: break
            }
            DebugLog.log("panel at 40,60 size \(Int(statusItem.panel?.frame.width ?? 0))x\(Int(statusItem.panel?.frame.height ?? 0))")
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { NSApp.terminate(nil) }
        }
    }
}
