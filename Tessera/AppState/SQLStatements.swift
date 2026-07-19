import Foundation

struct RunChoice: Equatable {
    var subselect: String
    var statement: String
}

enum SQLRunTarget: Equatable {
    /// A single unambiguous statement to run.
    case statement(String)
    /// The cursor sits inside a subselect — ask the user which to run.
    case ambiguous(RunChoice)
}

/// Resolves which SQL to run from the editor text and cursor position: the
/// statement (split on top-level `;`) containing the cursor, and — if the cursor
/// is inside a parenthesized subselect — offers that subselect as an alternative.
enum SQLStatements {

    static func resolve(sql: String, cursor: Int) -> SQLRunTarget {
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

    /// Range of the statement containing `cursor`, splitting on top-level `;`
    /// (ignoring semicolons inside strings and line comments).
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

        var start = 0
        var end = n
        for s in semicolons {
            if s < cursor { start = s + 1 }
            else { end = s; break }
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
