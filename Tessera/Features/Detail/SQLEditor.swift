import SwiftUI
import AppKit
import DBKit

/// SQL editor backed by `NSTextView`: regex syntax highlighting plus context-aware
/// autocompletion (SQL keywords, and schema/table/column names from the connected
/// database). `focusTrigger` increments to request keyboard focus (⌘L).
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    var schema: DatabaseTree?
    var focusTrigger: Int
    var cursor: Binding<Int>?
    /// Read-only mode: shows highlighted, selectable SQL that can't be edited
    /// (used to display a data view's generated query).
    var readOnly: Bool = false
    /// Which SQL dialect drives completion: keyword pools and identifier quoting
    /// differ between PostgreSQL and MySQL.
    var engine: DatabaseKind? = nil
    /// Called when the editor is clicked, so its pane takes focus in a tiled layout.
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let textView = CompletingTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.delegate = context.coordinator
        textView.isEditable = !readOnly
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
        textView.onFocus = onFocus
        // An editable NSTextView accepts string drags by default, which would eat a
        // tab dragged onto it (pasting its id) instead of letting the pane split.
        textView.unregisterDraggedTypes()
        context.coordinator.textView = textView
        context.coordinator.schema = schema
        context.coordinator.engine = engine
        if !readOnly {
            textView.completionSource = { [weak c = context.coordinator] text, caret, forced in
                c?.completion(text: text, caret: caret, forced: forced)
                    ?? (NSRange(location: caret, length: 0), [])
            }
            textView.onCommitRename = { [weak c = context.coordinator] from, to, inserted in
                c?.renameQualifier(from: from, to: to, insertedRange: inserted)
            }
        }
        textView.string = text
        context.coordinator.previousLength = (text as NSString).length
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView as? CompletingTextView else { return }
        textView.onFocus = onFocus
        context.coordinator.schema = schema
        context.coordinator.engine = engine
        // A pane reuses one editor (and its coordinator) across tab switches, but the
        // coordinator captured these bindings when it was born against a different tab.
        // Refresh them each update so edits write back to the tab now shown — otherwise
        // typing lands in the old tab and the next update wipes the visible editor.
        context.coordinator.text = $text
        context.coordinator.cursor = cursor
        if textView.string != text {
            textView.string = text
            context.coordinator.previousLength = (text as NSString).length
            context.coordinator.highlight()
        }
        if focusTrigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, cursor: cursor) }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var text: Binding<String>
        fileprivate var cursor: Binding<Int>?
        weak var textView: NSTextView?
        var lastFocusTrigger = 0
        var previousLength = 0

        var schema: DatabaseTree? { didSet { rebuildEngine() } }
        var engine: DatabaseKind? { didSet { rebuildEngine() } }

        /// The pure completion engine (in TesseraCore); rebuilt when the schema or
        /// dialect changes. The coordinator is just its editor-side shell.
        private var completionEngine = SQLCompletionEngine(schema: nil, engine: nil)
        private func rebuildEngine() { completionEngine = SQLCompletionEngine(schema: schema, engine: engine) }

        init(text: Binding<String>, cursor: Binding<Int>?) {
            self.text = text
            self.cursor = cursor
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            previousLength = (textView.string as NSString).length
            text.wrappedValue = textView.string
            highlight()
            applyAliasRewrites()
            // The completion popup is driven by CompletingTextView (Tab-only commit).
        }

        /// Reentrancy guard — an applied rename edits the text, re-entering
        /// `textDidChange`; the rewrite pass runs only from the outermost change.
        private var isApplyingAliasRewrite = false

        /// When a table gains an alias (`from action a`), rebind its full-name
        /// qualifiers in the statement to the alias (`action.name` → `a.name`). The
        /// engine decides which; this only applies the edits.
        private func applyAliasRewrites() {
            guard let textView, !isApplyingAliasRewrite else { return }
            let caret = textView.selectedRange().location
            let renames = completionEngine.pendingAliasRewrites(text: textView.string, caret: caret)
            guard !renames.isEmpty else { return }
            isApplyingAliasRewrite = true
            defer { isApplyingAliasRewrite = false }
            for rename in renames {
                applyRename(from: rename.from, to: rename.to, excluding: NSRange(location: caret, length: 0))
            }
        }

        /// Supplies the replace-range and candidates for the caret (schema-aware).
        func completion(text: String, caret: Int, forced: Bool) -> (NSRange, [SQLCompletionItem]) {
            let result = completionEngine.complete(text: text, caret: caret, forced: forced)
            return (result.range, result.items)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            cursor?.wrappedValue = textView.selectedRange().location
            updateStatementHighlight()
        }

        /// After a JOIN completion aliases a table, rebind existing `from.` qualifiers
        /// in the statement to `to.` (so a `select object.id` written before the join
        /// becomes `select o.id`).
        func renameQualifier(from: String, to: String, insertedRange: NSRange) {
            applyRename(from: from, to: to, excluding: insertedRange)
        }

        /// Applies one engine-computed qualifier rewrite to the live text view.
        private func applyRename(from: String, to: String, excluding: NSRange) {
            guard let textView,
                  let result = completionEngine.rename(text: textView.string, from: from, to: to,
                                                       caret: textView.selectedRange().location,
                                                       excluding: excluding)
            else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            guard textView.shouldChangeText(in: full, replacementString: result.text) else { return }
            textView.replaceCharacters(in: full, with: result.text)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: result.caret, length: 0))
            highlight()
        }

        // Reject automatic capitalization/autocorrect (case-only changes). Automatic
        // substitutions arrive via the plural method; manual typing via the singular.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacement = replacementString, affectedCharRange.length > 0 else { return true }
            let existing = (textView.string as NSString).substring(with: affectedCharRange)
            return !SQLText.isCaseOnlyChange(from: existing, to: replacement)
        }

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

        // MARK: Highlighting

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
            storage.setAttributes([.foregroundColor: NSColor.textColor, .font: SQLEditor.font], range: full)
            color(Self.numberRegex, in: string, range: full, storage: storage, color: .systemBlue)
            color(Self.keywordRegex, in: string, range: full, storage: storage, color: .systemPink)
            color(Self.stringRegex, in: string, range: full, storage: storage, color: .systemRed)
            color(Self.commentRegex, in: string, range: full, storage: storage, color: .secondaryLabelColor)
            storage.endEditing()
            updateStatementHighlight()
        }

        /// Whether the editor holds more than one runnable statement — cached on
        /// the text, since the caret moves far more often than the text changes.
        private var multiStatementText: (text: String, isMulti: Bool)?

        private func hasMultipleStatements(_ text: String) -> Bool {
            if let cached = multiStatementText, cached.text == text { return cached.isMulti }
            let real = SQLScript.statements(in: text).filter {
                // Comment-only chunks (a trailing "-- done") aren't statements.
                !SQLText.maskLiteralsAndComments($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let isMulti = real.count > 1
            multiStatementText = (text, isMulti)
            return isMulti
        }

        /// Faint background under the statement ⌘↩ would run — only shown when
        /// the editor holds more than one statement, where it actually informs.
        func updateStatementHighlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let ns = textView.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            storage.removeAttribute(.backgroundColor, range: full)
            guard hasMultipleStatements(textView.string),
                  var range = SQLStatements.statementNSRange(
                sql: textView.string, utf16Cursor: textView.selectedRange().location)
            else { return }
            // Trim surrounding whitespace so the tint hugs the SQL, not the gaps.
            while range.length > 0,
                  let scalar = Unicode.Scalar(ns.character(at: range.location)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                range = NSRange(location: range.location + 1, length: range.length - 1)
            }
            while range.length > 0,
                  let scalar = Unicode.Scalar(ns.character(at: range.location + range.length - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                range = NSRange(location: range.location, length: range.length - 1)
            }
            guard range.length > 0 else { return }
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.controlAccentColor.withAlphaComponent(0.07),
                                 range: range)
        }

        private func color(_ regex: NSRegularExpression, in string: String, range: NSRange,
                           storage: NSTextStorage, color: NSColor) {
            regex.enumerateMatches(in: string, range: range) { match, _, _ in
                if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }

    }
}
