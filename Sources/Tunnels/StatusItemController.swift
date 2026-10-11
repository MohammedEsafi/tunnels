import AppKit
import Observation
import SwiftUI
import TunnelsCore

/// The menu bar icon and the panel that drops down from it.
@MainActor
final class StatusItemController {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private(set) var panel: MenuPanel?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
            button.font = NSFont.menuBarFont(ofSize: 0)
        }
        render()
        observe()
    }

    /// Re-render the icon whenever the counts change.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = StatusItemController.archesGlyph()
        button.title = ""
        // Dimmed while nothing is forwarding, the way Wi-Fi dims when off.
        button.appearsDisabled = !model.controller.anyDesired
        button.toolTip = "Tunnels"
    }

    /// The app icon's receding arches at menu bar size, as a template image
    /// so it follows the menu bar's light or dark appearance. No count, no
    /// state: problems are reported by notification and inside the menu.
    static func archesGlyph() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setLineCap(.round)
            context.setLineWidth(1.9)

            // Outer arch, dim.
            let outer = CGMutablePath()
            outer.move(to: CGPoint(x: 3, y: 2))
            outer.addLine(to: CGPoint(x: 3, y: 8))
            outer.addArc(center: CGPoint(x: 9, y: 8), radius: 6, startAngle: .pi, endAngle: 0, clockwise: true)
            outer.addLine(to: CGPoint(x: 15, y: 2))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.addPath(outer)
            context.strokePath()

            // Inner arch, full.
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: 6.5, y: 2))
            inner.addLine(to: CGPoint(x: 6.5, y: 8))
            inner.addArc(center: CGPoint(x: 9, y: 8), radius: 2.5, startAngle: .pi, endAngle: 0, clockwise: true)
            inner.addLine(to: CGPoint(x: 11.5, y: 2))
            context.setStrokeColor(NSColor.black.cgColor)
            context.addPath(inner)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tunnels"
        return image
    }

    @objc func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        button.highlight(true)
        model.popoverVisible = true
        makePanel().show(below: buttonRect)
    }

    func close() {
        panel?.close()
    }

    /// Debug: show the panel at a fixed screen point.
    func openForSnapshot(topLeft: NSPoint) {
        model.popoverVisible = true
        makePanel().show(topLeft: topLeft)
    }

    private func makePanel() -> MenuPanel {
        if let panel { return panel }
        let root = PopoverView().environment(model)
        let panel = MenuPanel(rootView: root, onClose: { [weak self] in self?.panelDidClose() })
        self.panel = panel
        return panel
    }

    /// Every way the panel goes away ends here: the status item click, Escape,
    /// a click elsewhere, or another app taking focus.
    private func panelDidClose() {
        model.popoverVisible = false
        statusItem.button?.highlight(false)
    }
}
