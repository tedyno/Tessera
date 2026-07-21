import Foundation

public struct RunChoice: Equatable, Sendable {
    public var subselect: String
    public var statement: String
    public init(subselect: String, statement: String) {
        self.subselect = subselect
        self.statement = statement
    }
}

public enum SQLRunTarget: Equatable, Sendable {
    /// A single unambiguous statement to run.
    case statement(String)
    /// The cursor sits inside a subselect — ask the user which to run.
    case ambiguous(RunChoice)
}

/// Resolves which SQL to run from the editor text and cursor position: the
/// statement (split on top-level `;`) containing the cursor, and — if the cursor
/// is inside a parenthesized subselect — offers that subselect as an alternative.
public enum SQLStatements {

    public static func resolve(sql: String, cursor: Int) -> SQLRunTarget {
        let chars = Array(sql)
        let position = min(max(cursor, 0), chars.count)
        let (start, end) = statementBounds(chars, cursor: position)
        let statement = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)

        if let subselect = enclosingSubselect(chars, start: start, end: end, cursor: position) {
            let trimmed = subselect.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count < statement.count {
                return .ambiguous(RunChoice(subselect: trimmed, statement: statement))
            }
        }
        return .statement(statement)
    }

    /// UTF-16 range of the statement containing the cursor, for editor
    /// highlighting. nil when the text is empty or the cursor lands nowhere.
    public static func statementNSRange(sql: String, utf16Cursor: Int) -> NSRange? {
        let chars = Array(sql)
        guard !chars.isEmpty else { return nil }
        // The bounds walk characters; the editor speaks UTF-16 — convert both ways.
        let utf16 = sql.utf16
        let clamped = min(max(utf16Cursor, 0), utf16.count)
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: clamped)
            .samePosition(in: sql) ?? sql.startIndex
        let cursor = sql.distance(from: sql.startIndex, to: cursorIndex)
        let (start, end) = statementBounds(chars, cursor: cursor)
        guard start < end else { return nil }
        let lower = sql.index(sql.startIndex, offsetBy: start)
        let upper = sql.index(sql.startIndex, offsetBy: end)
        return NSRange(lower..<upper, in: sql)
    }

    /// Range of the statement containing `cursor`, splitting on top-level `;`
    /// (ignoring semicolons inside strings and line comments). When the cursor sits
    /// past the final `;` (in trailing whitespace), it resolves to the statement that
    /// just ended, so running there executes only that last statement.
    private static func statementBounds(_ chars: [Character], cursor: Int) -> (Int, Int) {
        var semicolons: [Int] = []
        var i = 0
        let n = chars.count
        var inString = false
        var inLineComment = false
        while i < n {
            let c = chars[i]
            if inLineComment {
                if c == "\n" { inLineComment = false }
                i += 1; continue
            }
            if inString {
                if c == "'" {
                    if i + 1 < n && chars[i + 1] == "'" { i += 2; continue }
                    inString = false
                }
                i += 1; continue
            }
            if c == "'" { inString = true; i += 1; continue }
            if c == "-", i + 1 < n, chars[i + 1] == "-" { inLineComment = true; i += 2; continue }
            if c == ";" { semicolons.append(i) }
            i += 1
        }

        // The statement ends at the first `;` at or just after the cursor (so a cursor
        // sitting right after a `;` belongs to the statement that just ended, not the
        // next one). Otherwise it's the trailing statement after the last `;`.
        var start = 0
        var end = n
        for s in semicolons {
            if cursor <= s + 1 { end = s; break }
            start = s + 1
        }
        return (start, end)
    }

    /// The innermost parenthesized `SELECT …` that encloses the cursor, if any.
    private static func enclosingSubselect(_ chars: [Character], start: Int, end: Int, cursor: Int) -> String? {
        var stack: [Int] = []
        var best: (open: Int, close: Int)?
        var i = start
        var inString = false
        var inLineComment = false
        while i < end {
            let c = chars[i]
            if inLineComment {
                if c == "\n" { inLineComment = false }
                i += 1; continue
            }
            if inString {
                if c == "'" {
                    if i + 1 < end && chars[i + 1] == "'" { i += 2; continue }
                    inString = false
                }
                i += 1; continue
            }
            if c == "'" { inString = true; i += 1; continue }
            if c == "-", i + 1 < end, chars[i + 1] == "-" { inLineComment = true; i += 2; continue }
            if c == "(" { stack.append(i) }
            else if c == ")", let open = stack.popLast() {
                if open < cursor, cursor <= i, startsWithSelect(chars, from: open + 1, to: i) {
                    if best == nil || open > best!.open { best = (open, i) }
                }
            }
            i += 1
        }
        guard let best else { return nil }
        return String(chars[(best.open + 1)..<best.close])
    }

    private static func startsWithSelect(_ chars: [Character], from: Int, to: Int) -> Bool {
        var j = from
        while j < to, chars[j].isWhitespace { j += 1 }
        guard j + 6 <= to, String(chars[j..<j + 6]).uppercased() == "SELECT" else { return false }
        // Require a word boundary so identifiers like `selected_col` don't match.
        let next = j + 6
        if next >= to { return true }
        let c = chars[next]
        return c.isWhitespace || c == "("
    }
}
