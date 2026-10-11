import AppKit
import SwiftUI

/// A bare NSTextField for editing in place inside a menu row: no bezel, no
/// focus ring, selects its contents when it appears. Return commits, Escape
/// cancels, losing focus commits.
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        private var finished = false
        init(_ parent: InlineTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish { parent.onCommit() }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish { parent.onCancel() }
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ note: Notification) {
            finish { parent.onCommit() }
        }

        private func finish(_ action: () -> Void) {
            guard !finished else { return }
            finished = true
            action()
        }
    }
}
