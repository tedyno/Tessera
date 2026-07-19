import SwiftUI
import AppKit

/// Single-line WHERE-filter field for data views, with autocompletion of the current
/// table's column names and common SQL operators. Completion only commits on Tab /
/// Return (never on arrow keys); Return submits when no completion is active.
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
        private var suppressCompletion = false
        private var isCompleting = false

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
            textView.needsDisplay = true   // repaint placeholder
            let length = (textView.string as NSString).length
            let isInsertion = length > previousLength
            previousLength = length
            guard isInsertion, !suppressCompletion, !isCompleting,
                  textView.selectedRange().length == 0, shouldComplete(textView) else {
                suppressCompletion = false
                return
            }
            isCompleting = true
            DispatchQueue.main.async { [weak self, weak textView] in
                textView?.complete(nil)
                self?.isCompleting = false
            }
        }

        /// Complete only right after an identifier character and never inside a string.
        private func shouldComplete(_ textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= ns.length else { return false }
            let previous = ns.substring(with: NSRange(location: caret - 1, length: 1))
            guard let character = previous.first,
                  character.isLetter || character.isNumber || character == "_" else { return false }
            let before = ns.substring(to: caret)
            return before.reduce(0, { $1 == "'" ? $0 + 1 : $0 }) % 2 == 0
        }

        func textView(_ textView: NSTextView, completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange).lowercased()
            guard !partial.isEmpty else { return [] }
            index?.pointee = 0
            return (columns + Self.keywords)
                .filter { $0.lowercased().hasPrefix(partial) && $0.lowercased() != partial }
        }

        /// Blocks automatic capitalization/autocorrect that only changes the case of
        /// already-typed text (e.g. "li" → "Li"), while allowing real edits.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacement = replacementString, affectedCharRange.length > 0,
                  affectedCharRange.length == (replacement as NSString).length else { return true }
            let existing = (textView.string as NSString).substring(with: affectedCharRange)
            return !(existing != replacement && existing.lowercased() == replacement.lowercased())
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.deleteBackward(_:)):
                suppressCompletion = true
                return false
            default:
                return false
            }
        }
    }
}
