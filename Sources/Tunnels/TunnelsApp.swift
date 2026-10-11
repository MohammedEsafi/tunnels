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
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        let controller = StatusItemController(model: model)
        statusItem = controller
        DebugSnapshot.scheduleIfRequested(statusItem: controller)

        // A plain SIGTERM (kill, logout, pkill) skips applicationShouldTerminate
        // and would orphan the ssh masters. Route it through the same cleanup.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            AppModel.shared.prepareForQuitNow()
            exit(0)
        }
        source.resume()
        termSource = source
    }

    /// Close every forward we own before the process goes away, whether the
    /// quit came from our menu, ⌘Q, or a system shutdown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.prepareForQuitNow()
        return .terminateNow
    }
}
