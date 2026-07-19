import SwiftUI
import AppKit

/// Single-line WHERE-filter field for data views, with autocompletion of the current
/// table's column names and common SQL operators. Submits on Return.
struct FilterField: NSViewRepresentable {
    @Binding var text: String
    var columns: [String]
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        (field.cell as? NSTextFieldCell)?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.columns = columns
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, columns: columns, onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var columns: [String]
        var onSubmit: () -> Void
        private var previousLength = 0

        /// Operators handy inside a WHERE clause, offered alongside column names.
        private static let keywords = [
            "AND", "OR", "NOT", "LIKE", "ILIKE", "IN", "IS NULL", "IS NOT NULL", "BETWEEN",
        ]

        init(text: Binding<String>, columns: [String], onSubmit: @escaping () -> Void) {
            self.text = text
            self.columns = columns
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
            // Only pop the completion list while inserting, so Backspace can delete.
            let isInsertion = field.stringValue.count > previousLength
            previousLength = field.stringValue.count
            if isInsertion, let editor = field.currentEditor() as? NSTextView {
                DispatchQueue.main.async { [weak editor] in editor?.complete(nil) }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                     forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange).lowercased()
            guard !partial.isEmpty else { return [] }
            let pool = columns + Self.keywords
            return pool.filter { $0.lowercased().hasPrefix(partial) && $0.lowercased() != partial }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }
    }
}
