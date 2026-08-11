import SwiftUI
import AppKit
import DBKit

/// Plain-text value editor backed by `NSTextView` — unlike SwiftUI's `TextEditor`
/// it can color ranges, which powers the JSON syntax highlighting. One component
/// for every value: coloring only kicks in when the text starts an object/array
/// (per `JSONText.scan`), so numbers, dates, and prose stay plain.
struct ValueTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    /// Values at or below this re-highlight synchronously on every keystroke;
    /// larger ones coalesce so typing into a big JSON doesn't rescan each key.
    private static let synchronousHighlightLimit = 32_768

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let textView = NSTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = Self.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        // An editable NSTextView accepts string drags by default; the sheet has no
        // drop targets of its own, so keep drags out entirely (SQLEditor precedent).
        textView.unregisterDraggedTypes()
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.text = $text
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let keyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var text: Binding<String>
        weak var textView: NSTextView?
        private var pendingHighlight: DispatchWorkItem?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            if (textView.string as NSString).length <= ValueTextEditor.synchronousHighlightLimit {
                pendingHighlight?.cancel()
                pendingHighlight = nil
                highlight()
            } else {
                pendingHighlight?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.highlight() }
                pendingHighlight = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }

        /// Colors from the Core tokenizer, palette aligned with `JSONNodeLabel`:
        /// string red, number blue, bool purple, null/punctuation secondary, keys
        /// bold. Invalid JSON still colors the tokens before the error, so a value
        /// mid-edit doesn't flicker to plain. Over `JSONText.sizeLimit` the scan
        /// returns nil and the text stays plain.
        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let string = textView.string
            let full = NSRange(location: 0, length: (string as NSString).length)
            storage.beginEditing()
            storage.setAttributes([.foregroundColor: NSColor.textColor, .font: ValueTextEditor.font],
                                  range: full)
            if let result = JSONText.scan(string), result.isContainer {
                for token in result.tokens {
                    switch token.kind {
                    case .objectKey:
                        storage.addAttribute(.font, value: ValueTextEditor.keyFont, range: token.range)
                    case .string:
                        storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: token.range)
                    case .number:
                        storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: token.range)
                    case .bool:
                        storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: token.range)
                    case .null, .punctuation:
                        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                             range: token.range)
                    }
                }
            }
            storage.endEditing()
        }
    }
}
