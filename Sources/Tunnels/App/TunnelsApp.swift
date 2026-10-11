import AppKit
import TunnelsCore

/// Plain AppKit entry point. SwiftUI's MenuBarExtra gives an opaque window;
/// Control Center style menus need our own status item and panel.
@main
enum TunnelsMain {
    static func main() {
        exitIfAlreadyRunning()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Two copies would share the favourites file, the state file and the
    /// control sockets, and each one's launch sweep would kill the other's
    /// ssh masters. A sandboxed copy with its own socket directory is allowed.
    private static func exitIfAlreadyRunning() {
        guard let identifier = Bundle.main.bundleIdentifier,
              ProcessInfo.processInfo.environment["TUNNELS_SOCKET_DIR"] == nil else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        others.first?.activate()
        exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        let controller = StatusItemController(model: model)
        statusItem = controller
        DebugSnapshot.scheduleIfRequested(model: model, statusItem: controller)

        // A plain SIGTERM (kill, logout, pkill) skips applicationShouldTerminate
        // and would orphan the ssh masters. Route it through the same cleanup.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            model.prepareForQuitNow()
            exit(0)
        }
        source.resume()
        termSource = source
    }

    /// Close every forward we own before the process goes away, whether the
    /// quit came from our menu, ⌘Q, or a system shutdown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.prepareForQuitNow()
        return .terminateNow
    }
}
