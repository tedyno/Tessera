import Foundation

/// Pure text helpers for the SQL editor and data-view filter, kept in the core so
/// they can be unit-tested (the AppKit editors that use them can't be).
public enum SQLText {
    /// True when the end of `prefix` sits inside an unclosed single-quoted string
    /// literal (odd number of `'`). Used to suppress autocomplete inside values,
    /// so typing `'Li%'` isn't turned into `LIKE`.
    public static func isInsideStringLiteral(_ prefix: String) -> Bool {
        prefix.reduce(0) { $1 == "'" ? $0 + 1 : $0 } % 2 == 1
    }

    /// True when `replacement` differs from `existing` only by letter case — the
    /// signature of automatic capitalization/autocorrect, which we reject so typed
    /// SQL isn't "corrected" (`li` → `Li`).
    public static func isCaseOnlyChange(from existing: String, to replacement: String) -> Bool {
        existing != replacement && existing.lowercased() == replacement.lowercased()
    }

    /// Candidates in `pool` that continue `partial` (case-insensitive prefix),
    /// excluding an exact match. Input order is preserved.
    public static func completions(for partial: String, in pool: [String]) -> [String] {
        let lower = partial.lowercased()
        guard !lower.isEmpty else { return [] }
        return pool.filter { $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower }
    }

    /// Blanks the contents of string literals and comments (length preserved) so
    /// keyword matching can't be fooled by text inside them.
    public static func maskLiteralsAndComments(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if character == "-", next == "-" {                    // -- line comment
                while index < characters.count, characters[index] != "\n" {
                    output.append(" "); index += 1
                }
                continue
            }
            if character == "/", next == "*" {                    // /* block comment */
                output.append(" "); output.append(" "); index += 2
                while index < characters.count,
                      !(characters[index] == "*" && index + 1 < characters.count && characters[index + 1] == "/") {
                    output.append(" "); index += 1
                }
                if index < characters.count { output.append(" "); output.append(" "); index += 2 }
                continue
            }
            if character == "'" {                                  // 'string literal'
                output.append(character); index += 1
                while index < characters.count {
                    if characters[index] == "'" { output.append("'"); index += 1; break }
                    output.append(" "); index += 1
                }
                continue
            }
            output.append(character); index += 1
        }
        return output
    }

    /// A plain `INSERT`/`UPDATE`/`DELETE` (no `RETURNING`): a data-modifying command
    /// whose only result is an affected-row count, not a row set. Lets a driver take
    /// the metadata path to report "N rows affected".
    public static func isDML(_ sql: String) -> Bool {
        if sql.range(of: #"(?i)\breturning\b"#, options: .regularExpression) != nil { return false }
        switch leadingKeyword(sql) {
        case "INSERT", "UPDATE", "DELETE": return true
        default: return false
        }
    }

    /// The first SQL keyword, skipping leading whitespace and `--` / `/* */` comments.
    public static func leadingKeyword(_ sql: String) -> String {
        var s = Substring(sql)
        while true {
            s = s.drop(while: \.isWhitespace)
            if s.hasPrefix("--") { s = s.drop(while: { $0 != "\n" }); continue }
            if s.hasPrefix("/*") {
                guard let range = s.range(of: "*/") else { break }
                s = s[range.upperBound...]
                continue
            }
            break
        }
        return String(s.prefix(while: { $0.isLetter })).uppercased()
    }

    /// The range (UTF-16) of the identifier word ending at `caret` — the run of
    /// letters/digits/underscore immediately before it. Length 0 when the caret isn't
    /// after such a character.
    public static func identifierRange(in text: String, caret: Int) -> NSRange {
        let ns = text as NSString
        let position = min(max(caret, 0), ns.length)
        var start = position
        while start > 0 {
            let character = ns.substring(with: NSRange(location: start - 1, length: 1)).first
            guard let character, character.isLetter || character.isNumber || character == "_" else { break }
            start -= 1
        }
        return NSRange(location: start, length: position - start)
    }
}
