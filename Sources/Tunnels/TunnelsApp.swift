import AppKit
import TunnelsCore

/// Plain AppKit entry point. SwiftUI's MenuBarExtra gives an opaque window;
/// Control Center style menus need our own status item and panel.
@main
enum TunnelsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        let controller = StatusItemController(model: model)
        statusItem = controller
        DebugSnapshot.scheduleIfRequested(statusItem: controller)
    }

    /// Close every forward we own before the process goes away, whether the
    /// quit came from our menu, ⌘Q, or a system shutdown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.prepareForQuitNow()
        return .terminateNow
    }
}
