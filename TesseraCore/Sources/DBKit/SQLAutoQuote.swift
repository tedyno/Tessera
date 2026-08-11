import Foundation

/// Rewrites bare (unquoted) values compared against non-numeric columns into
/// proper single-quoted SQL literals, so `status = active`, `email = a@b.com` or
/// `created >= 2026-01-01` just work in the WHERE filter and the editor.
///
/// Deliberately conservative: a value is only touched when the left side resolves
/// to a known non-numeric column and the bare text could not mean anything else —
/// not a column/table/alias, keyword, number, parameter, function call, or an
/// existing literal. Every input it rewrites would otherwise have been an error,
/// so the meaning of already-valid SQL never changes.
public enum SQLAutoQuote {

    /// What identifiers mean in the statement being quoted.
    public struct Scope: Sendable {
        /// Lowercased column name → declared type, for "is the LHS a text column".
        public var columnTypes: [String: String]
        /// Every name (column, table, alias) a bare word could legitimately be.
        public var identifiers: Set<String>

        public init(columnTypes: [String: String], identifiers: Set<String>) {
            self.columnTypes = columnTypes
            self.identifiers = identifiers
        }

        /// Scope of a single-table WHERE fragment (the data view's filter bar).
        public init(table: SchemaTable) {
            var types: [String: String] = [:]
            var names: Set<String> = [table.name.lowercased()]
            for column in table.columns {
                let key = column.name.lowercased()
                types[key] = types[key] ?? column.dataType
                names.insert(key)
            }
            self.init(columnTypes: types, identifiers: names)
        }
    }

    /// `sql` with bare compared values quoted. Works on a WHERE fragment and on a
    /// full statement alike — the strict candidate rules keep every other clause
    /// position (SELECT list, ON, SET, …) safe without clause parsing.
    public static func quoted(_ sql: String, scope: Scope) -> String {
        guard !scope.columnTypes.isEmpty else { return sql }
        let masked = SQLText.maskLiteralsAndComments(sql)
        let chars = Array(sql)
        let maskedChars = Array(masked)
        var edits: [(range: Range<Int>, replacement: String)] = []

        let full = NSRange(masked.startIndex..., in: masked)
        for match in Self.comparison.matches(in: masked, range: full) {
            guard let identRange = charRange(match.range(at: 1), in: masked),
                  let opRange = charRange(match.range(at: 2), in: masked) else { continue }
            let column = lastIdentifierComponent(String(maskedChars[identRange])).lowercased()
            guard let type = scope.columnTypes[column], !SQLTypes.isNumeric(type) else { continue }

            let op = String(maskedChars[opRange]).uppercased()
            if op.hasSuffix("IN") {
                edits += inListEdits(from: opRange.upperBound, chars: chars,
                                     masked: maskedChars, scope: scope)
            } else if op.hasSuffix("BETWEEN") {
                edits += betweenEdits(from: opRange.upperBound, chars: chars,
                                      masked: maskedChars, scope: scope)
            } else if let edit = spanEdit(from: opRange.upperBound, chars: chars,
                                          masked: maskedChars, scope: scope) {
                edits.append(edit)
            }
        }
        guard !edits.isEmpty else { return sql }

        var out = chars
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: edit.replacement)
        }
        return String(out)
    }

    // MARK: Comparison heads

    /// `column op` — a (possibly qualified/quoted) identifier followed by a
    /// comparison operator. The value itself is scanned manually afterwards,
    /// because its end depends on nesting and keywords, not a fixed shape.
    private static let comparison: NSRegularExpression = {
        let ident = #"(?:[A-Za-z_][\w$]*|"[^"]+"|`[^`]+`)"#
        let ops = #"!=|<>|<=|>=|=|<|>|(?:NOT\s+)?I?LIKE\b|(?:NOT\s+)?BETWEEN\b|(?:NOT\s+)?IN\b"#
        return try! NSRegularExpression(
            pattern: "(?i)(\(ident)(?:\\.\(ident))*)\\s*(\(ops))")
    }()

    /// The last component of a possibly qualified identifier, unquoted:
    /// `u."Name"` → `Name`.
    private static func lastIdentifierComponent(_ identifier: String) -> String {
        let last: Substring
        if identifier.hasSuffix("\"") || identifier.hasSuffix("`") {
            let quote = identifier.last!
            let body = identifier.dropLast()
            last = body.suffix(from: body.lastIndex(of: quote).map { body.index(after: $0) }
                                        ?? body.startIndex)
        } else {
            last = identifier.split(separator: ".").last ?? Substring(identifier)
        }
        return String(last)
    }

    // MARK: Value spans

    /// Keywords that end a value span at nesting depth 0.
    private static let boundaries: Set<String> = [
        "AND", "OR", "GROUP", "ORDER", "LIMIT", "OFFSET", "HAVING", "UNION",
        "INTERSECT", "EXCEPT", "RETURNING", "WINDOW", "FETCH", "FOR", "THEN",
        "ELSE", "END", "WHEN", "ASC", "DESC", "FROM", "WHERE", "JOIN", "LEFT",
        "RIGHT", "INNER", "CROSS", "FULL", "NATURAL", "ON", "USING", "SET",
        "VALUES", "SELECT",
    ]

    /// Bare words that are values already and must never be quoted.
    private static let valueKeywords: Set<String> = [
        "NULL", "TRUE", "FALSE", "DEFAULT", "NOT", "EXISTS", "CASE", "INTERVAL",
        "ANY", "ALL", "SOME", "ROW", "ARRAY", "CURRENT_DATE", "CURRENT_TIME",
        "CURRENT_TIMESTAMP", "LOCALTIME", "LOCALTIMESTAMP",
    ]

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }

    /// The value span starting at `from` (after the operator): first non-space
    /// character up to a boundary keyword, top-level comma/paren/operator, or the
    /// end — trailing whitespace trimmed. Nil when the span opens with `(`
    /// (an expression or subquery, never a bare value).
    private static func valueSpan(from: Int, masked: [Character]) -> Range<Int>? {
        var i = from
        while i < masked.count, masked[i].isWhitespace { i += 1 }
        guard i < masked.count, masked[i] != "(" else { return nil }
        let start = i
        var depth = 0
        while i < masked.count {
            let c = masked[i]
            if c == "(" { depth += 1; i += 1; continue }
            if c == ")" {
                if depth == 0 { break }
                depth -= 1; i += 1; continue
            }
            if depth == 0 {
                if c == "," || c == ";" { break }
                if "=<>!".contains(c) { break }
                if isIdentifierChar(c), c.isLetter || c == "_",
                   i == 0 || !isIdentifierChar(masked[i - 1]) {
                    var end = i
                    while end < masked.count, isIdentifierChar(masked[end]) { end += 1 }
                    if boundaries.contains(String(masked[i..<end]).uppercased()) { break }
                    i = end; continue
                }
            }
            i += 1
        }
        var end = i
        while end > start, masked[end - 1].isWhitespace { end -= 1 }
        return start < end ? start..<end : nil
    }

    /// The quoting edit for the span, or nil when the value must be left alone.
    private static func edit(for span: Range<Int>, chars: [Character],
                             masked: [Character], scope: Scope) -> (Range<Int>, String)? {
        // A masked quote means part of the span is already a string literal.
        guard !masked[span].contains("'") else { return nil }
        let value = String(chars[span])
        guard let first = value.first else { return nil }
        if "$:?@".contains(first) { return nil }                       // parameter / variable
        if value.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil {
            return nil                                                 // plain number
        }
        let firstWord = value.prefix(while: { isIdentifierChar($0) })
        if valueKeywords.contains(firstWord.uppercased()) { return nil }
        if value.range(of: #"^[A-Za-z_][\w$]*\s*\("#, options: .regularExpression) != nil {
            return nil                                                 // function call
        }
        if value.range(of: #"^[A-Za-z_][\w$]*$"#, options: .regularExpression) != nil,
           scope.identifiers.contains(value.lowercased()) {
            return nil                                                 // column-to-column
        }
        if value.range(of: #"^[A-Za-z_][\w$]*(\.[A-Za-z_][\w$]*)+$"#,
                       options: .regularExpression) != nil,
           let head = value.split(separator: ".").first,
           scope.identifiers.contains(head.lowercased()) {
            return nil                                                 // qualified column
        }
        // `name = "John"`: a double-quoted value is an identifier to the engine —
        // when it names no column it can only be a misquoted string, so fix it.
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2,
           !value.dropFirst().dropLast().contains("\"") {
            let inner = String(value.dropFirst().dropLast())
            guard !scope.identifiers.contains(inner.lowercased()) else { return nil }
            return (span, "'" + inner.replacingOccurrences(of: "'", with: "''") + "'")
        }
        return (span, "'" + value.replacingOccurrences(of: "'", with: "''") + "'")
    }

    private static func spanEdit(from: Int, chars: [Character], masked: [Character],
                                 scope: Scope) -> (range: Range<Int>, replacement: String)? {
        guard let span = valueSpan(from: from, masked: masked) else { return nil }
        return edit(for: span, chars: chars, masked: masked, scope: scope)
    }

    /// `BETWEEN a AND b` — two spans joined by the operator's own AND.
    private static func betweenEdits(from: Int, chars: [Character], masked: [Character],
                                     scope: Scope) -> [(range: Range<Int>, replacement: String)] {
        guard let low = valueSpan(from: from, masked: masked) else { return [] }
        var edits: [(range: Range<Int>, replacement: String)] = []
        if let edit = edit(for: low, chars: chars, masked: masked, scope: scope) {
            edits.append(edit)
        }
        // Step over the connecting AND, then take the upper bound's span.
        var i = low.upperBound
        while i < masked.count, masked[i].isWhitespace { i += 1 }
        let word = i
        while i < masked.count, isIdentifierChar(masked[i]) { i += 1 }
        guard String(masked[word..<i]).uppercased() == "AND",
              let high = valueSpan(from: i, masked: masked) else { return edits }
        if let edit = edit(for: high, chars: chars, masked: masked, scope: scope) {
            edits.append(edit)
        }
        return edits
    }

    /// `IN (a, b, c)` — every top-level element is its own candidate. A subquery
    /// (`IN (SELECT …)`) is left untouched as a whole.
    private static func inListEdits(from: Int, chars: [Character], masked: [Character],
                                    scope: Scope) -> [(range: Range<Int>, replacement: String)] {
        var i = from
        while i < masked.count, masked[i].isWhitespace { i += 1 }
        guard i < masked.count, masked[i] == "(" else { return [] }
        i += 1
        var edits: [(range: Range<Int>, replacement: String)] = []
        var depth = 0
        var elementStart = i
        func flush(_ end: Int) {
            var start = elementStart, last = end
            while start < last, masked[start].isWhitespace { start += 1 }
            while last > start, masked[last - 1].isWhitespace { last -= 1 }
            guard start < last, masked[start] != "(" else { return }
            if let edit = edit(for: start..<last, chars: chars, masked: masked, scope: scope) {
                edits.append(edit)
            }
        }
        while i < masked.count {
            let c = masked[i]
            if c == "(" { depth += 1 }
            else if c == ")" {
                if depth == 0 { flush(i); break }
                depth -= 1
            } else if c == ",", depth == 0 {
                flush(i)
                elementStart = i + 1
            } else if depth == 0, isIdentifierChar(c),
                      String(masked[i...].prefix(7)).uppercased().hasPrefix("SELECT"),
                      i == elementStart || masked[(elementStart..<i)].allSatisfy(\.isWhitespace) {
                return []                                              // subquery, not a list
            }
            i += 1
        }
        return edits
    }

    // MARK: Index mapping

    /// UTF-16 `NSRange` in `text` → offsets into `Array(text)`. The masked text
    /// swaps literal contents for spaces, so UTF-16 offsets can drift from the
    /// original — character offsets stay aligned (masking is per-character).
    private static func charRange(_ range: NSRange, in text: String) -> Range<Int>? {
        guard let bounds = Range(range, in: text) else { return nil }
        return text.distance(from: text.startIndex, to: bounds.lowerBound)
            ..< text.distance(from: text.startIndex, to: bounds.upperBound)
    }
}
