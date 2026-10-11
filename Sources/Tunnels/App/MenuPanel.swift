import AppKit
import SwiftUI

/// A Control Center style panel: borderless, translucent vibrancy material,
/// rounded corners, shadow, closes on click outside or Escape. It can become
/// key without activating the app, so the text field works.
@MainActor
final class MenuPanel: NSPanel, NSWindowDelegate {
    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 13
    static let gapBelowMenuBar: CGFloat = 5

    private let hostingView: NSHostingView<AnyView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchorTopLeft: NSPoint = .zero
    /// Room between the anchor and the bottom of the screen's visible area.
    private var heightBudget: CGFloat = .infinity
    private let onClose: () -> Void

    init<Content: View>(rootView: Content, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let sized = rootView
            .frame(width: MenuPanel.width)
            .background(SizeReporter())
        hostingView = NSHostingView(rootView: AnyView(sized))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MenuPanel.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = MenuPanel.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect

        NotificationCenter.default.addObserver(forName: SizeReporter.changed, object: nil, queue: .main) { [weak self] note in
            guard let self, let size = note.object as? NSValue else { return }
            Task { @MainActor in self.resize(to: size.sizeValue) }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Showing

    func show(below buttonRect: NSRect) {
        let size = hostingView.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: buttonRect.midX, y: buttonRect.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = buttonRect.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = buttonRect.minY - MenuPanel.gapBelowMenuBar
        heightBudget = top - visible.minY - 8
        show(topLeft: NSPoint(x: x, y: top))
    }

    func show(topLeft: NSPoint) {
        anchorTopLeft = topLeft
        let height = min(hostingView.fittingSize.height, heightBudget)
        setFrame(NSRect(x: topLeft.x, y: topLeft.y - height, width: MenuPanel.width, height: height), display: false)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        installMonitors()
    }

    override func close() {
        let wasVisible = isVisible
        removeMonitors()
        super.close()
        if wasVisible { onClose() }
    }

    private func resize(to size: CGSize) {
        guard isVisible, size.height > 0 else { return }
        let height = min(size.height, heightBudget)
        let frame = NSRect(x: anchorTopLeft.x, y: anchorTopLeft.y - height, width: MenuPanel.width, height: height)
        if frame != self.frame { setFrame(frame, display: true) }
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event } // Escape
            // An inline editor owns Escape while it is active: it cancels the edit.
            if let editor = self.firstResponder as? NSTextView, editor.isFieldEditor,
               (editor.delegate as? NSTextField)?.delegate is InlineTextField.Coordinator {
                return event
            }
            Task { @MainActor in self.close() }
            return nil
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Switching to another app, or a system alert: behave like a menu.
        if isVisible { close() }
    }
}

/// Reports the SwiftUI content size so the panel can follow it.
struct SizeReporter: View {
    static let changed = Notification.Name("tunnels.panel.size")

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { post(proxy.size) }
                .onChange(of: proxy.size) { _, next in post(next) }
        }
    }

    private func post(_ size: CGSize) {
        NotificationCenter.default.post(name: SizeReporter.changed, object: NSValue(size: size))
    }
}
