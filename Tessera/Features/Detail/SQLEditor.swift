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
        context.coordinator.engine = engine
        if !readOnly {
            textView.completionSource = { [weak c = context.coordinator] text, caret, forced in
                c?.completion(text: text, caret: caret, forced: forced)
                    ?? (NSRange(location: caret, length: 0), [])
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
        context.coordinator.engine = engine
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
        var engine: DatabaseKind?

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
        func completion(text: String, caret: Int, forced: Bool) -> (NSRange, [SQLCompletionItem]) {
            let ns = text as NSString
            guard caret > 0, caret <= ns.length,
                  !SQLText.isInsideStringLiteral(ns.substring(to: caret)) else {
                return (NSRange(location: caret, length: 0), [])
            }
            let range = SQLText.identifierRange(in: text, caret: caret)
            let partial = range.length > 0 ? ns.substring(with: range) : ""
            let before = ns.substring(to: range.location)
            let items = completionItems(partial: partial, before: before, fullText: text, forced: forced)
            return (range, items)
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

        /// Keywords every supported dialect understands.
        private static let commonKeywords: [String] = [
            "SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN",
            "GROUP BY", "ORDER BY", "LIMIT", "OFFSET", "INSERT INTO", "VALUES", "UPDATE",
            "SET", "DELETE FROM", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT", "IN", "LIKE",
            "BETWEEN", "IS NULL", "IS NOT NULL", "ASC", "DESC", "HAVING", "UNION", "CASE",
            "WHEN", "THEN", "ELSE", "END", "EXISTS", "COUNT(", "SUM(", "AVG(", "MIN(",
            "MAX(", "COALESCE(", "CAST(", "NOW()",
        ]
        private static let postgresKeywords: [String] = [
            "ILIKE", "RETURNING", "ON CONFLICT", "DO NOTHING", "DO UPDATE SET",
            "DISTINCT ON (", "STRING_AGG(", "ARRAY_AGG(", "JSON_AGG(", "JSONB_AGG(",
            "GENERATE_SERIES(", "DATE_TRUNC(", "INTERVAL", "FOR UPDATE",
        ]
        private static let mysqlKeywords: [String] = [
            "ON DUPLICATE KEY UPDATE", "REPLACE INTO", "GROUP_CONCAT(", "IFNULL(",
            "CURDATE()", "DATE_FORMAT(", "JSON_EXTRACT(", "STRAIGHT_JOIN", "AUTO_INCREMENT",
        ]

        private var keywordPool: [String] {
            switch engine {
            case .mysql: Self.commonKeywords + Self.mysqlKeywords
            case .postgres: Self.commonKeywords + Self.postgresKeywords
            default: Self.commonKeywords
            }
        }

        private struct TableInfo {
            let schema: String
            let name: String
            let columns: [(name: String, type: String)]
        }

        private var allTables: [TableInfo] = []
        private var tableByLower: [String: TableInfo] = [:]
        private var tablesBySchemaLower: [String: [TableInfo]] = [:]
        private var schemaNames: [String] = []

        private func rebuildCompletionData() {
            allTables = []; tableByLower = [:]; tablesBySchemaLower = [:]; schemaNames = []
            guard let schema else { return }
            for namespace in schema.schemas {
                schemaNames.append(namespace.name)
                for table in namespace.tables {
                    let info = TableInfo(schema: namespace.name, name: table.name,
                                         columns: table.columns.map { ($0.name, $0.dataType) })
                    allTables.append(info)
                    tableByLower[table.name.lowercased()] = info
                    tablesBySchemaLower[namespace.name.lowercased(), default: []].append(info)
                }
            }
        }

        // MARK: Statement context (tables + aliases in the query being written)

        private static let aliasRegex = try! NSRegularExpression(
            pattern: #"(?i)\b(from|join|update|into)\s+([`"]?[\w$]+[`"]?(?:\.[`"]?[\w$]+[`"]?)?)(?:\s+(?:as\s+)?([A-Za-z_][\w$]*))?"#)
        /// Words that can follow a table reference but are never its alias.
        private static let aliasStopWords: Set<String> = [
            "where", "join", "left", "right", "inner", "outer", "cross", "full", "natural",
            "on", "using", "group", "order", "limit", "offset", "set", "having", "union",
            "values", "returning", "for", "window", "fetch", "as", "straight_join",
        ]

        /// Tables referenced by the SQL being written, plus alias → table mappings —
        /// so `a.` offers the columns of `accounts a`, and columns of referenced
        /// tables outrank the rest of the database.
        private func statementContext(_ text: String) -> (tables: [TableInfo], aliases: [String: TableInfo]) {
            var tables: [TableInfo] = []
            var seen: Set<String> = []
            var aliases: [String: TableInfo] = [:]
            let ns = text as NSString
            Self.aliasRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let rawTable = ns.substring(with: match.range(at: 2))
                let cleaned = rawTable.replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                let tableName = cleaned.split(separator: ".").last.map(String.init) ?? cleaned
                guard let info = tableByLower[tableName.lowercased()] else { return }
                if seen.insert(info.name.lowercased()).inserted { tables.append(info) }
                if match.range(at: 3).location != NSNotFound {
                    let alias = ns.substring(with: match.range(at: 3)).lowercased()
                    if !Self.aliasStopWords.contains(alias) { aliases[alias] = info }
                }
            }
            return (tables, aliases)
        }

        // MARK: Candidates

        private static let tableContextKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"]

        private func completionItems(partial: String, before: String,
                                     fullText: String, forced: Bool) -> [SQLCompletionItem] {
            let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = statementContext(fullText)
            // (candidate, priority) — lower priority sorts first within equal rank.
            var pool: [(item: SQLCompletionItem, priority: Int)] = []

            if trimmed.hasSuffix(".") {
                let qualifier = Self.lastIdentifier(in: String(trimmed.dropLast())).lowercased()
                if let info = context.aliases[qualifier] ?? tableByLower[qualifier] {
                    pool = info.columns.map { (columnItem($0.name, detail: $0.type), 0) }
                } else if engine != .mysql, let tables = tablesBySchemaLower[qualifier] {
                    // In MySQL a "schema" is the database itself — no schema. prefix.
                    pool = tables.map { (tableItem($0, detail: nil), 0) }
                } else {
                    pool = contextColumnPool(context, fallbackToAll: true)
                }
            } else if Self.tableContextKeywords.contains(Self.lastToken(in: before).uppercased()) {
                pool = allTables.map { (tableItem($0, detail: engine == .mysql ? nil : $0.schema), 0) }
                if engine != .mysql {
                    pool += schemaNames.map { (schemaItem($0), 1) }
                }
            } else {
                // Free position: don't pop up on every space — only with a prefix
                // typed, or when explicitly asked (⌃Space).
                guard !partial.isEmpty || forced else { return [] }
                pool = contextColumnPool(context, fallbackToAll: false)
                pool += allTables.map { (tableItem($0, detail: engine == .mysql ? nil : $0.schema), 2) }
                pool += keywordPool.map { (keywordItem($0), 3) }
                pool += globalColumnPool(excluding: context)
            }

            let query = partial.lowercased()
            var seen: Set<String> = []
            return pool
                .compactMap { entry -> (SQLCompletionItem, Int, Int)? in
                    guard let rank = Self.matchRank(entry.item.label, query: query) else { return nil }
                    return (entry.item, rank, entry.priority)
                }
                .sorted { ($0.1, $0.2, $0.0.label.lowercased()) < ($1.1, $1.2, $1.0.label.lowercased()) }
                .compactMap { entry in
                    seen.insert(entry.0.label.lowercased() + "\u{1}" + (entry.0.detail ?? "")).inserted
                        ? entry.0 : nil
                }
                .prefix(50)
                .map { $0 }
        }

        /// Columns of the tables the statement references (priority 0), annotated
        /// with their type; falls back to every column in the database when asked.
        private func contextColumnPool(_ context: (tables: [TableInfo], aliases: [String: TableInfo]),
                                       fallbackToAll: Bool) -> [(item: SQLCompletionItem, priority: Int)] {
            let tables = context.tables.isEmpty && fallbackToAll ? allTables : context.tables
            return tables.flatMap { info in
                info.columns.map { (columnItem($0.name, detail: $0.type), 0) }
            }
        }

        /// Columns of every *other* table (priority 4), annotated with their table —
        /// still reachable, but never ahead of what the statement actually uses.
        private func globalColumnPool(
            excluding excluded: (tables: [TableInfo], aliases: [String: TableInfo])
        ) -> [(item: SQLCompletionItem, priority: Int)] {
            let excludedNames = Set(excluded.tables.map { $0.name.lowercased() })
            return allTables
                .filter { !excludedNames.contains($0.name.lowercased()) }
                .flatMap { info in
                    info.columns.map { (columnItem($0.name, detail: info.name), 4) }
                }
        }

        // MARK: Item builders

        private func keywordItem(_ keyword: String) -> SQLCompletionItem {
            SQLCompletionItem(insert: keyword, label: keyword, detail: nil,
                              kind: keyword.hasSuffix("(") || keyword.hasSuffix(")") ? .function : .keyword)
        }

        private func tableItem(_ info: TableInfo, detail: String?) -> SQLCompletionItem {
            SQLCompletionItem(insert: quoteIfNeeded(info.name), label: info.name,
                              detail: detail, kind: .table)
        }

        private func columnItem(_ name: String, detail: String?) -> SQLCompletionItem {
            SQLCompletionItem(insert: quoteIfNeeded(name), label: name, detail: detail, kind: .column)
        }

        private func schemaItem(_ name: String) -> SQLCompletionItem {
            SQLCompletionItem(insert: quoteIfNeeded(name), label: name, detail: nil, kind: .schema)
        }

        // MARK: Matching & quoting

        /// nil = no match; 0 = prefix, 1 = a word inside starts with it, 2 = substring.
        private static func matchRank(_ candidate: String, query: String) -> Int? {
            guard !query.isEmpty else { return 0 }
            let lower = candidate.lowercased()
            if lower == query { return nil }   // already fully typed
            if lower.hasPrefix(query) { return 0 }
            if lower.split(whereSeparator: { $0 == "_" || $0 == " " }).dropFirst()
                .contains(where: { $0.hasPrefix(query) }) { return 1 }
            if lower.contains(query) { return 2 }
            return nil
        }

        /// Identifiers the target dialect can't take bare: PostgreSQL folds unquoted
        /// names to lowercase (so mixed case must be quoted), MySQL mostly needs
        /// quoting for reserved words and special characters.
        private func quoteIfNeeded(_ name: String) -> String {
            let reserved = Self.reservedWords.contains(name.uppercased())
            switch engine {
            case .mysql:
                let plain = name.range(of: "^[A-Za-z_][A-Za-z0-9_$]*$", options: .regularExpression) != nil
                return plain && !reserved ? name
                    : "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
            default:
                let plain = name.range(of: "^[a-z_][a-z0-9_$]*$", options: .regularExpression) != nil
                return plain && !reserved ? name
                    : "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
        }

        /// The highlight keywords plus common reserved names that aren't in it.
        private static let reservedWords: Set<String> = keywords.union([
            "USER", "CHECK", "CONSTRAINT", "GRANT", "TO", "EXISTS", "ANY", "SOME",
            "BOTH", "DO", "ONLY", "COLLATE", "COLUMN", "CURRENT_DATE", "CURRENT_TIME",
        ])

        private static func lastToken(in string: String) -> String {
            string.split(whereSeparator: { " \n\t,()".contains($0) }).last.map(String.init) ?? ""
        }

        private static func lastIdentifier(in string: String) -> String {
            let identifier = string.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return String(identifier.reversed())
        }
    }
}
