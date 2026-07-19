import SwiftUI
import AppKit

/// A lightweight SQL editor backed by `NSTextView` (no external dependency) with
/// regex-based syntax highlighting for keywords, strings, numbers and comments.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = Self.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            highlight()
        }

        private static let keywords: Set<String> = [
            "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "FULL", "INNER", "OUTER",
            "CROSS", "ON", "USING", "GROUP", "BY", "ORDER", "LIMIT", "OFFSET", "INSERT",
            "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "VIEW", "INDEX",
            "DROP", "ALTER", "ADD", "COLUMN", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT",
            "IN", "LIKE", "ILIKE", "BETWEEN", "IS", "ASC", "DESC", "HAVING", "UNION", "ALL",
            "CASE", "WHEN", "THEN", "ELSE", "END", "WITH", "RETURNING", "PRIMARY", "KEY",
            "FOREIGN", "REFERENCES", "DEFAULT", "TRUE", "FALSE", "COUNT", "SUM", "AVG",
            "MIN", "MAX", "COALESCE", "CAST",
        ]

        private static let keywordRegex = try! NSRegularExpression(
            pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
        private static let stringRegex = try! NSRegularExpression(pattern: "'([^'\\\\]|\\\\.)*'")
        private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
        private static let commentRegex = try! NSRegularExpression(pattern: "--[^\\n]*")

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let string = textView.string
            let full = NSRange(location: 0, length: (string as NSString).length)

            storage.beginEditing()
            storage.setAttributes([
                .foregroundColor: NSColor.textColor,
                .font: SQLEditor.font,
            ], range: full)

            color(Self.numberRegex, in: string, range: full, storage: storage, color: .systemBlue)
            color(Self.keywordRegex, in: string, range: full, storage: storage, color: .systemPink)
            color(Self.stringRegex, in: string, range: full, storage: storage, color: .systemRed)
            color(Self.commentRegex, in: string, range: full, storage: storage, color: .secondaryLabelColor)
            storage.endEditing()
        }

        private func color(_ regex: NSRegularExpression, in string: String, range: NSRange,
                           storage: NSTextStorage, color: NSColor) {
            regex.enumerateMatches(in: string, range: range) { match, _, _ in
                if let r = match?.range {
                    storage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        }
    }
}
