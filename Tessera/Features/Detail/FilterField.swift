import SwiftUI
import AppKit
import DBKit

/// Single-line WHERE-filter field for data views. Uses the same custom completion as
/// the SQL editor (Tab/Return commit while the popup is open) and submits on Return
/// once it's closed.
struct FilterField: NSViewRepresentable {
    @Binding var text: String
    var columns: [String]
    var placeholder: String
    /// Called with the field's current text on Return.
    var onSubmit: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        // Chrome comes from SwiftUI (translucent rounded background) — the
        // system bezel would paint an opaque grey box over the backdrop.
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = CompletingTextView(frame: .zero)
        textView.drawsBackground = false
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 3, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.completionSource = { [weak c = context.coordinator] text, caret, forced in
            c?.completion(text: text, caret: caret, forced: forced)
                ?? (NSRange(location: caret, length: 0), [])
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.previousLength = (text as NSString).length
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.columns = columns
        context.coordinator.onSubmit = onSubmit
        (textView as? CompletingTextView)?.placeholder = placeholder
        if textView.string != text {
            textView.string = text
            context.coordinator.previousLength = (text as NSString).length
            textView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, columns: columns, onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var columns: [String]
        var onSubmit: (String) -> Void
        weak var textView: NSTextView?
        var previousLength = 0

        private static let keywords = [
            "AND", "OR", "NOT", "LIKE", "ILIKE", "IN", "IS NULL", "IS NOT NULL", "BETWEEN",
        ]

        init(text: Binding<String>, columns: [String], onSubmit: @escaping (String) -> Void) {
            self.text = text
            self.columns = columns
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            previousLength = (textView.string as NSString).length
            textView.needsDisplay = true   // repaint placeholder
        }

        /// Candidates for the caret: the table's columns plus WHERE operators, unless
        /// the caret is inside a string literal.
        func completion(text: String, caret: Int, forced: Bool) -> (NSRange, [SQLCompletionItem]) {
            let ns = text as NSString
            guard caret > 0, caret <= ns.length,
                  !SQLText.isInsideStringLiteral(ns.substring(to: caret)) else {
                return (NSRange(location: caret, length: 0), [])
            }
            let range = SQLText.identifierRange(in: text, caret: caret)
            guard range.length > 0 || forced else { return (range, []) }
            let partial = range.length > 0 ? ns.substring(with: range) : ""
            let names = partial.isEmpty
                ? columns + Self.keywords   // ⌃Space with no prefix: offer everything
                : SQLText.completions(for: partial, in: columns + Self.keywords)
            let columnSet = Set(columns)
            return (range, names.map {
                SQLCompletionItem(insert: $0, label: $0, detail: nil,
                                  kind: columnSet.contains($0) ? .column : .keyword)
            })
        }

        // Reject automatic case-only substitutions that bypass the field editor.
        func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                      replacementStrings: [String]?) -> Bool {
            guard let replacements = replacementStrings, replacements.count == affectedRanges.count else { return true }
            let ns = textView.string as NSString
            for (offset, value) in affectedRanges.enumerated() {
                let range = value.rangeValue
                guard range.length > 0, range.location + range.length <= ns.length else { continue }
                if SQLText.isCaseOnlyChange(from: ns.substring(with: range), to: replacements[offset]) {
                    return false
                }
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Return submits the filter with the field's actual text (not via the
            // binding, which could lag). The popup captures Return itself when open.
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                text.wrappedValue = textView.string
                onSubmit(textView.string)
                return true
            }
            return false
        }
    }
}
