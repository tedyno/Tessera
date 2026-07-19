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
        context.coordinator.textView = textView
        context.coordinator.schema = schema
        if !readOnly {
            textView.completionSource = { [weak c = context.coordinator] text, caret in
                c?.completion(text: text, caret: caret) ?? (NSRange(location: caret, length: 0), [])
            }
        }
        textView.string = text
        context.coordinator.previousLength = (text as NSString).length
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.schema = schema
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
        private let text: Binding<String>
        private let cursor: Binding<Int>?
        weak var textView: NSTextView?
        var lastFocusTrigger = 0
        var previousLength = 0

        var schema: DatabaseTree? { didSet { rebuildCompletionData() } }

        init(text: Binding<String>, cursor: Binding<Int>?) {
            self.text = text
            self.cursor = cursor
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            previousLength = (textView.string as NSString).length
            text.wrappedValue = textView.string
            highlight()
            // The completion popup is driven by CompletingTextView (Tab-only commit).
        }

        /// Supplies the replace-range and candidates for the caret (schema-aware).
        func completion(text: String, caret: Int) -> (NSRange, [String]) {
            let ns = text as NSString
            guard caret > 0, caret <= ns.length,
                  !SQLText.isInsideStringLiteral(ns.substring(to: caret)) else {
                return (NSRange(location: caret, length: 0), [])
            }
            let range = SQLText.identifierRange(in: text, caret: caret)
            guard range.length > 0 else { return (range, []) }
            let partial = ns.substring(with: range)
            let before = ns.substring(to: range.location)
            return (range, completionCandidates(partial: partial, before: before))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            cursor?.wrappedValue = textView.selectedRange().location
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
        }

        private func color(_ regex: NSRegularExpression, in string: String, range: NSRange,
                           storage: NSTextStorage, color: NSColor) {
            regex.enumerateMatches(in: string, range: range) { match, _, _ in
                if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }

        // MARK: Autocomplete data

        private static let completionKeywords: [String] = [
            "SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN",
            "GROUP BY", "ORDER BY", "LIMIT", "OFFSET", "INSERT INTO", "VALUES", "UPDATE",
            "SET", "DELETE FROM", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT", "IN", "LIKE",
            "BETWEEN", "IS NULL", "IS NOT NULL", "ASC", "DESC", "HAVING", "UNION", "CASE",
            "WHEN", "THEN", "ELSE", "END", "COUNT(", "SUM(", "AVG(", "MIN(", "MAX(",
        ]

        private var tableNames: [String] = []
        private var columnNames: [String] = []
        private var schemaNames: [String] = []
        private var columnsByTable: [String: [String]] = [:]
        private var tablesBySchema: [String: [String]] = [:]

        private func rebuildCompletionData() {
            tableNames = []; columnNames = []; schemaNames = []
            columnsByTable = [:]; tablesBySchema = [:]
            guard let schema else { return }
            var tables: Set<String> = [], columns: Set<String> = []
            for namespace in schema.schemas {
                schemaNames.append(namespace.name)
                for table in namespace.tables {
                    tables.insert(table.name)
                    tablesBySchema[namespace.name.lowercased(), default: []].append(table.name)
                    let cols = table.columns.map(\.name)
                    columnsByTable[table.name.lowercased()] = cols
                    cols.forEach { columns.insert($0) }
                }
            }
            tableNames = tables.sorted()
            columnNames = columns.sorted()
        }

        private func completionCandidates(partial: String, before: String) -> [String] {
            let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
            var pool: [String]

            if trimmed.hasSuffix(".") {
                let identifier = Self.lastIdentifier(in: String(trimmed.dropLast())).lowercased()
                if let cols = columnsByTable[identifier] {
                    pool = cols
                } else if let tbls = tablesBySchema[identifier] {
                    pool = tbls
                } else {
                    pool = columnNames
                }
            } else {
                let previous = Self.lastToken(in: before).uppercased()
                if ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"].contains(previous) {
                    pool = tableNames + schemaNames
                } else {
                    pool = Self.completionKeywords + tableNames + columnNames
                }
            }

            let lower = partial.lowercased()
            guard !lower.isEmpty else { return Array(pool.prefix(60)) }
            return pool
                .filter { $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower }
                .sorted()
        }

        private static func lastToken(in string: String) -> String {
            string.split(whereSeparator: { " \n\t,()".contains($0) }).last.map(String.init) ?? ""
        }

        private static func lastIdentifier(in string: String) -> String {
            let identifier = string.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return String(identifier.reversed())
        }
    }
}
