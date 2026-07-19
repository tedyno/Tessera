import SwiftUI
import AppKit
import DBKit

/// Single-line WHERE-filter field for data views. Uses the same custom completion as
/// the SQL editor (list shows while typing, only Tab commits) and submits on Return.
struct FilterField: NSViewRepresentable {
    @Binding var text: String
    var columns: [String]
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        let textView = CompletingTextView(frame: .zero)
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
        textView.completionSource = { [weak c = context.coordinator] text, caret in
            c?.completion(text: text, caret: caret) ?? (NSRange(location: caret, length: 0), [])
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
        var onSubmit: () -> Void
        weak var textView: NSTextView?
        var previousLength = 0

        private static let keywords = [
            "AND", "OR", "NOT", "LIKE", "ILIKE", "IN", "IS NULL", "IS NOT NULL", "BETWEEN",
        ]

        init(text: Binding<String>, columns: [String], onSubmit: @escaping () -> Void) {
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
        func completion(text: String, caret: Int) -> (NSRange, [String]) {
            let ns = text as NSString
            guard caret > 0, caret <= ns.length,
                  !SQLText.isInsideStringLiteral(ns.substring(to: caret)) else {
                return (NSRange(location: caret, length: 0), [])
            }
            let range = SQLText.identifierRange(in: text, caret: caret)
            guard range.length > 0 else { return (range, []) }
            let partial = ns.substring(with: range)
            return (range, SQLText.completions(for: partial, in: columns + Self.keywords))
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
            // Return submits the filter (the popup captures Return itself when open).
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }
    }
}
