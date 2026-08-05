import SwiftUI
import AppKit
import DBKit

/// Single-line WHERE-filter field for data views. Shares the SQL editor's
/// schema-aware completion engine (`SQLCompletionEngine`): it offers the filtered
/// table's columns with type / PK / FK / NOT NULL badges, plus the operators and
/// scalar functions a predicate uses. When the schema hasn't loaded it falls back
/// to the grid's result column names. Tab/Return commit while the popup is open;
/// Return submits the filter once it's closed.
struct FilterField: NSViewRepresentable {
    @Binding var text: String
    /// The table the filter runs against, so completion is scoped to its columns.
    var table: String?
    /// Live schema and dialect for the connection; drive the rich completion.
    var schema: DatabaseTree?
    var engine: DatabaseKind?
    /// Fallback column names (from the current result) used before the schema loads.
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
        context.coordinator.table = table
        context.coordinator.columns = columns
        context.coordinator.schema = schema
        context.coordinator.engine = engine
        context.coordinator.onSubmit = onSubmit
        (textView as? CompletingTextView)?.placeholder = placeholder
        if textView.string != text {
            textView.string = text
            context.coordinator.previousLength = (text as NSString).length
            textView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, table: table, schema: schema, engine: engine,
                    columns: columns, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var table: String?
        var columns: [String]
        var onSubmit: (String) -> Void
        weak var textView: NSTextView?
        var previousLength = 0

        /// The shared pure engine (TesseraCore); rebuilt when schema/dialect change.
        var schema: DatabaseTree? { didSet { rebuildEngine() } }
        var engine: DatabaseKind? { didSet { rebuildEngine() } }
        private var completionEngine: SQLCompletionEngine
        private func rebuildEngine() { completionEngine = SQLCompletionEngine(schema: schema, engine: engine) }

        init(text: Binding<String>, table: String?, schema: DatabaseTree?, engine: DatabaseKind?,
             columns: [String], onSubmit: @escaping (String) -> Void) {
            self.text = text
            self.table = table
            self.schema = schema
            self.engine = engine
            self.columns = columns
            self.onSubmit = onSubmit
            self.completionEngine = SQLCompletionEngine(schema: schema, engine: engine)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            previousLength = (textView.string as NSString).length
            textView.needsDisplay = true   // repaint placeholder
        }

        /// Schema-aware candidates for the caret, scoped to the filtered table.
        func completion(text: String, caret: Int, forced: Bool) -> (NSRange, [SQLCompletionItem]) {
            let result = completionEngine.completeFilter(text: text, caret: caret, table: table,
                                                         fallbackColumns: columns, forced: forced)
            return (result.range, result.items)
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
