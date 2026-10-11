import AppKit
import Network
import UserNotifications

/// Wake from sleep and network path changes, delivered on the main actor.
final class SystemEvents {
    static let shared = SystemEvents()

    private var monitor: NWPathMonitor?
    private var sawFirstPath = false
    private var handler: (@MainActor () -> Void)?

    func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.fire()
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // The first callback describes the current path, not a change.
            if !sawFirstPath {
                sawFirstPath = true
                return
            }
            if path.status == .satisfied {
                DispatchQueue.main.async { self.fire() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "tunnels.network"))
        self.monitor = monitor
    }

    private func fire() {
        DebugLog.log("system event: wake or network change")
        guard let handler else { return }
        Task { @MainActor in handler() }
    }
}

/// Posts user notifications. Authorisation is asked for when the setting is
/// switched on, and again the first time there is something to say.
enum Notifier {
    /// Notification APIs trap in a process without a bundle (`swift run`).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// True when the user has turned notifications off for the app in System Settings.
    static func isDenied() async -> Bool {
        guard available else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static func post(title: String, body: String) {
        DebugLog.log("notification: \(title) — \(body)")
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
