import SwiftUI
import AppKit
import DBKit

/// SQL editor backed by `NSTextView`: regex syntax highlighting plus context-aware
/// autocompletion (SQL keywords, and schema/table/column names from the connected
/// database). `focusTrigger` increments to request keyboard focus (⌘L).
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    /// The session's cached schema-aware completion engine (nil = no completion).
    /// Built once per schema generation by `ConnectionSession` — the editor must
    /// not rebuild it per keystroke.
    var completion: SQLCompletionEngine?
    var focusTrigger: Int
    var cursor: Binding<Int>?
    /// Length of the selection at `cursor`, so ⌘↩ can run everything the user
    /// highlighted rather than just the statement the caret happens to sit in.
    var selectionLength: Binding<Int>?
    /// Read-only mode: shows highlighted, selectable SQL that can't be edited
    /// (used to display a data view's generated query).
    var readOnly: Bool = false
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
        // ⌘F in the editor is the standard text find bar (⌘G, replace, and all),
        // not the grid's row filter — `AppModel.performFind` routes by focus.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.onFocus = onFocus
        // An editable NSTextView accepts string drags by default, which would eat a
        // tab dragged onto it (pasting its id) instead of letting the pane split.
        textView.unregisterDraggedTypes()
        context.coordinator.textView = textView
        context.coordinator.completionEngine = completion
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
        context.coordinator.observeScrolling(of: scrollView)
        context.coordinator.highlight()
        context.coordinator.scheduleDeferredWork()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView as? CompletingTextView else { return }
        textView.onFocus = onFocus
        context.coordinator.completionEngine = completion
        // A pane reuses one editor (and its coordinator) across tab switches, but the
        // coordinator captured these bindings when it was born against a different tab.
        // Refresh them each update so edits write back to the tab now shown — otherwise
        // typing lands in the old tab and the next update wipes the visible editor.
        context.coordinator.text = $text
        context.coordinator.cursor = cursor
        context.coordinator.selectionLength = selectionLength
        if textView.string != text {
            textView.string = text
            context.coordinator.previousLength = (text as NSString).length
            context.coordinator.textVersion &+= 1
            context.coordinator.highlight()
            context.coordinator.scheduleDeferredWork()
        }
        if focusTrigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, cursor: cursor, selectionLength: selectionLength)
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var text: Binding<String>
        fileprivate var cursor: Binding<Int>?
        fileprivate var selectionLength: Binding<Int>?
        weak var textView: NSTextView?
        var lastFocusTrigger = 0
        var previousLength = 0

        /// The session's cached pure completion engine (in TesseraCore); assigned
        /// from `updateNSView` — a cheap struct copy, never a rebuild. Nil while
        /// no session/schema exists.
        var completionEngine: SQLCompletionEngine?

        init(text: Binding<String>, cursor: Binding<Int>?, selectionLength: Binding<Int>?) {
            self.text = text
            self.cursor = cursor
            self.selectionLength = selectionLength
        }

        /// Highlighting covers the viewport, so text that scrolls into it has to be
        /// coloured as it arrives. Cheap: the pass is bounded by the viewport, and
        /// `rehighlightVisible` returns immediately while the new viewport is still
        /// inside what was already coloured. (A selector observer rather than a
        /// block one: the observer is released with the coordinator, and the block
        /// form would have to be `@Sendable`.)
        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(viewportDidChange),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        @objc private func viewportDidChange() { rehighlightVisible() }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            previousLength = (textView.string as NSString).length
            text.wrappedValue = textView.string
            textVersion &+= 1
            highlight()
            scheduleDeferredWork()
            // The completion popup is driven by CompletingTextView (Tab-only commit).
        }

        /// Reentrancy guard — an applied rename edits the text, re-entering
        /// `textDidChange`; the rewrite pass runs only from the outermost change.
        private var isApplyingAliasRewrite = false

        /// When a table gains an alias (`from action a`), rebind its full-name
        /// qualifiers in the statement to the alias (`action.name` → `a.name`). The
        /// engine decides which; this only applies the edits.
        private func applyAliasRewrites() {
            guard let textView, let completionEngine, !isApplyingAliasRewrite else { return }
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
            guard let completionEngine else { return (NSRange(location: caret, length: 0), []) }
            let result = completionEngine.complete(text: text, caret: caret, forced: forced)
            return (result.range, result.items)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            cursor?.wrappedValue = selection.location
            selectionLength?.wrappedValue = selection.length
            applyStatementTint()
        }

        /// After a JOIN completion aliases a table, rebind existing `from.` qualifiers
        /// in the statement to `to.` (so a `select object.id` written before the join
        /// becomes `select o.id`).
        func renameQualifier(from: String, to: String, insertedRange: NSRange) {
            applyRename(from: from, to: to, excluding: insertedRange)
        }

        /// Applies one engine-computed qualifier rewrite to the live text view.
        private func applyRename(from: String, to: String, excluding: NSRange) {
            guard let textView, let completionEngine,
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

        /// Colours what is on screen (plus a screenful of margin), not the whole
        /// document.
        ///
        /// The four regex passes and the attribute writes are both proportional to
        /// the range they cover, and this used to run over the entire text on every
        /// keystroke — 38 ms per character in a 112 KB script, which is five dropped
        /// frames. Scoping it to the viewport makes the cost of typing independent
        /// of how long the file is; `rehighlightVisible` covers the rest as it
        /// scrolls into view.
        func highlight() {
            highlightedRange = nil        // a fresh pass, not a scroll: recolour now
            rehighlightVisible()
        }

        /// The range already coloured, so scrolling within it costs nothing.
        private var highlightedRange: NSRange?

        func rehighlightVisible() {
            guard let textView, let storage = textView.textStorage else { return }
            let string = textView.string
            let length = (string as NSString).length
            let visible = visibleCharacterRange(length: length)
            if let done = highlightedRange, NSIntersectionRange(done, visible) == visible { return }

            let range = paddedRange(visible, length: length)
            storage.beginEditing()
            storage.setAttributes([.foregroundColor: NSColor.textColor, .font: SQLEditor.font], range: range)
            color(Self.numberRegex, in: string, range: range, storage: storage, color: .systemBlue)
            color(Self.keywordRegex, in: string, range: range, storage: storage, color: .systemPink)
            color(Self.stringRegex, in: string, range: range, storage: storage, color: .systemRed)
            color(Self.commentRegex, in: string, range: range, storage: storage, color: .secondaryLabelColor)
            storage.endEditing()
            highlightedRange = range
            applyStatementTint()
        }

        /// What the scroll view is showing, in characters. Asked of the text view
        /// rather than a layout manager so it holds for TextKit 1 and 2 alike.
        private func visibleCharacterRange(length: Int) -> NSRange {
            guard let textView, length > 0 else { return NSRange(location: 0, length: 0) }
            let rect = textView.visibleRect
            // Before the first layout there is no viewport yet; the top is what
            // will be shown, and the bounds-change notification corrects it as soon
            // as the scroll view has a size.
            guard !rect.isEmpty else { return NSRange(location: 0, length: min(length, 8000)) }
            let top = textView.characterIndexForInsertion(at: NSPoint(x: rect.minX, y: rect.minY))
            let bottom = textView.characterIndexForInsertion(at: NSPoint(x: rect.maxX, y: rect.maxY))
            let lower = min(max(0, min(top, bottom)), length)
            let upper = min(max(lower, max(top, bottom)), length)
            return NSRange(location: lower, length: upper - lower)
        }

        /// The visible range grown by a margin and out to line boundaries.
        ///
        /// The margin means a short scroll needs no repaint, and starting at a line
        /// boundary keeps a comment (`--` to end of line) whole. A string literal
        /// running past the margin is the one thing this can miscolour — it is
        /// recoloured the moment its opening quote scrolls into range.
        private func paddedRange(_ visible: NSRange, length: Int) -> NSRange {
            guard length > 0 else { return NSRange(location: 0, length: 0) }
            // Wide enough that ordinary scrolling rarely repaints, small enough
            // that a repaint stays well inside a frame even in a 450 KB script.
            let margin = 1500
            let lower = max(0, visible.location - margin)
            let upper = min(length, visible.upperBound + margin)
            let ns = textView?.string as NSString? ?? ""
            let lineStart = ns.lineRange(for: NSRange(location: lower, length: 0)).location
            let lineEnd = ns.lineRange(for: NSRange(location: max(lineStart, upper - 1), length: 0)).upperBound
            return NSRange(location: lineStart, length: min(length, lineEnd) - lineStart)
        }

        /// The statement split for the text as it was at `version`, computed off
        /// the main thread. Both the tint and the alias rewrites read it, so a
        /// caret move is a lookup rather than a rescan of the whole document.
        private struct StatementSplit {
            let version: Int
            let ranges: [NSRange]
            /// Whether the editor holds more than one *runnable* statement — a
            /// comment-only chunk ("-- done") is not one.
            let isMulti: Bool
        }
        private var split: StatementSplit?
        /// Bumped on every edit, so a split computed for older text is ignored.
        var textVersion = 0

        private var deferredTask: Task<Void, Never>?

        /// Recomputes the statement split shortly after typing stops, and applies
        /// what depends on it.
        ///
        /// Splitting is a pass over the whole document (20 ms for 450 KB) and the
        /// alias rewrite needs it too, so neither belongs on the keystroke path.
        /// The delay is only felt by the faint tint under the statement ⌘↩ would
        /// run and by the alias rebinding, both of which are cosmetic until you
        /// stop typing. ⌘↩ itself never reads this cache — it resolves the target
        /// from the live text.
        func scheduleDeferredWork() {
            guard let textView else { return }
            let text = textView.string
            let version = textVersion
            deferredTask?.cancel()
            deferredTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let computed = await Task.detached(priority: .userInitiated) {
                    (ranges: SQLStatements.statementNSRanges(sql: text),
                     isMulti: Self.isMultiStatement(text))
                }.value
                guard !Task.isCancelled, let self, self.textVersion == version else { return }
                self.split = StatementSplit(version: version, ranges: computed.ranges,
                                            isMulti: computed.isMulti)
                self.applyStatementTint()
                self.applyAliasRewrites()
            }
        }

        /// Comment-only chunks (a trailing "-- done") aren't statements.
        /// `nonisolated` because it runs on the background task with the split.
        nonisolated private static func isMultiStatement(_ text: String) -> Bool {
            let real = SQLScript.statements(in: text).filter {
                !SQLText.maskLiteralsAndComments($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return real.count > 1
        }

        /// Faint background under the statement ⌘↩ would run — only shown when
        /// the editor holds more than one statement, where it actually informs.
        ///
        /// Reads the cached split, so it costs nothing on a caret move. While the
        /// split is stale (text edited, recompute pending) the tint is left as it
        /// is rather than flickering off and back on.
        func applyStatementTint() {
            guard let textView, let storage = textView.textStorage else { return }
            guard let split, split.version == textVersion else { return }
            let ns = textView.string as NSString
            // Clear only where the tint actually is: wiping the attribute across
            // the whole document would put an O(text) step back on the keystroke
            // path, which is what this pass exists to get rid of.
            if let previous = tintedRange {
                let clamped = NSIntersectionRange(previous, NSRange(location: 0, length: ns.length))
                if clamped.length > 0 { storage.removeAttribute(.backgroundColor, range: clamped) }
                tintedRange = nil
            }
            guard split.isMulti,
                  var range = SQLStatements.statement(at: textView.selectedRange().location,
                                                      in: split.ranges),
                  range.upperBound <= ns.length
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
            tintedRange = range
        }

        /// Where the statement tint currently sits, so it can be lifted again
        /// without touching the rest of the document.
        private var tintedRange: NSRange?

        private func color(_ regex: NSRegularExpression, in string: String, range: NSRange,
                           storage: NSTextStorage, color: NSColor) {
            regex.enumerateMatches(in: string, range: range) { match, _, _ in
                if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }

    }
}
