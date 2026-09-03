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
        statement(at: utf16Cursor, in: statementNSRanges(sql: sql))
    }

    /// Every top-level statement's range, in the editor's UTF-16 units and in
    /// document order, from a single pass over the text. Splits on top-level `;`,
    /// ignoring semicolons inside strings and line comments — the same rule
    /// `statementNSRange` applies, which is now expressed in terms of this.
    ///
    /// Exists so the editor can compute the split once per edit and resolve the
    /// caret against the result: finding the statement under the caret used to
    /// rescan the whole document on every arrow key.
    public static func statementNSRanges(sql: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0            // UTF-16 offset where the current statement begins
        var offset = 0           // UTF-16 offset of the character being looked at
        var inString = false
        var inLineComment = false
        var previous: Character?

        for character in sql {
            let width = character.utf16.count
            defer { offset += width; previous = character }
            if inLineComment {
                if character == "\n" { inLineComment = false }
                continue
            }
            if inString {
                // A doubled '' closes and immediately reopens the literal, which
                // leaves the state — and so every boundary — exactly where
                // treating it as one escaped quote would.
                if character == "'" { inString = false }
                continue
            }
            if character == "'" { inString = true; continue }
            if character == "-", previous == "-" { inLineComment = true; continue }
            if character == ";" {
                ranges.append(NSRange(location: start, length: offset - start))
                start = offset + width
            }
        }
        ranges.append(NSRange(location: start, length: max(0, offset - start)))
        return ranges
    }

    /// The statement `utf16Cursor` sits in, resolved against precomputed ranges.
    ///
    /// A cursor sitting just after a `;` belongs to the statement that ended there,
    /// not the one starting after it — so running from there executes what you just
    /// finished typing. Returns nil for an empty statement (e.g. the caret past a
    /// trailing `;`), which is what the caller shows no tint for.
    public static func statement(at utf16Cursor: Int, in ranges: [NSRange]) -> NSRange? {
        guard let last = ranges.last else { return nil }
        let cursor = max(utf16Cursor, 0)
        for range in ranges.dropLast() where cursor <= range.upperBound + 1 {
            return range.length > 0 ? range : nil
        }
        return last.length > 0 ? last : nil
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
