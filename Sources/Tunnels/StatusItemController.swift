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
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let active = model.controller.activeCount
        let dropped = model.controller.droppedCount
        let symbol = dropped > 0 ? "arrow.left.arrow.right.circle" : "arrow.left.arrow.right"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tunnels")?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.title = active > 0 || dropped > 0 ? " \(active)" : ""
        button.appearsDisabled = active == 0 && dropped == 0 && !model.controller.anyDesired
        button.toolTip = dropped > 0
            ? "Tunnels: \(active) active, \(dropped) dropped"
            : (active > 0 ? "Tunnels: \(active) active" : "Tunnels: nothing forwarding")
    }

    @objc func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        if panel == nil {
            let root = PopoverView().environment(model)
            panel = MenuPanel(rootView: root, onClose: { [weak self] in self?.statusItem.button?.highlight(false) })
        }
        guard let panel, let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.ignoreClicksIn = buttonRect
        button.highlight(true)
        model.popoverVisible = true
        panel.show(below: buttonRect)
    }

    func close() {
        panel?.close()
        model.popoverVisible = false
        statusItem.button?.highlight(false)
    }

    /// Debug: show the panel at a fixed screen point.
    func openForSnapshot(topLeft: NSPoint) {
        if panel == nil {
            let root = PopoverView().environment(model)
            panel = MenuPanel(rootView: root, onClose: {})
        }
        model.popoverVisible = true
        panel?.show(topLeft: topLeft)
    }
}
