import Foundation

/// Splits a `.sql` script into individual statements for sequential execution.
/// Semicolons inside string literals, quoted identifiers, `--` / `/* */` comments,
/// and PostgreSQL dollar-quoted blocks (`$$…$$`, `$body$…$body$`) are not treated as
/// separators. (MySQL `DELIMITER` redefinition is not handled.)
public enum SQLScript {
    public static func statements(in sql: String) -> [String] {
        let chars = Array(sql)
        let count = chars.count
        var statements: [String] = []
        var current = ""
        var index = 0

        func peek(_ offset: Int) -> Character? {
            let position = index + offset
            return position < count ? chars[position] : nil
        }

        while index < count {
            let character = chars[index]

            // Line comment: -- … end of line
            if character == "-", peek(1) == "-" {
                while index < count, chars[index] != "\n" { current.append(chars[index]); index += 1 }
                continue
            }
            // Block comment: /* … */
            if character == "/", peek(1) == "*" {
                current.append("/"); current.append("*"); index += 2
                while index < count, !(chars[index] == "*" && peek(1) == "/") { current.append(chars[index]); index += 1 }
                if index < count { current.append("*"); current.append("/"); index += 2 }
                continue
            }
            // Quoted string / identifier: '…', "…", `…`
            if character == "'" || character == "\"" || character == "`" {
                let quote = character
                current.append(character); index += 1
                while index < count {
                    current.append(chars[index])
                    if chars[index] == quote {
                        if quote == "'", peek(1) == "'" { current.append("'"); index += 2; continue }  // '' escape
                        index += 1; break
                    }
                    index += 1
                }
                continue
            }
            // Dollar-quoted block: $tag$ … $tag$
            if character == "$", let tag = dollarTag(chars, at: index) {
                current += tag; index += tag.count
                while index < count {
                    if chars[index] == "$", matches(chars, at: index, tag: tag) {
                        current += tag; index += tag.count; break
                    }
                    current.append(chars[index]); index += 1
                }
                continue
            }
            // Statement terminator
            if character == ";" {
                appendStatement(&statements, current)
                current = ""; index += 1
                continue
            }
            current.append(character); index += 1
        }
        appendStatement(&statements, current)
        return statements
    }

    private static func appendStatement(_ statements: inout [String], _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { statements.append(trimmed) }
    }

    /// If a dollar-quote tag starts at `at` (`$`), returns it (e.g. "$$" or "$body$").
    private static func dollarTag(_ chars: [Character], at start: Int) -> String? {
        var i = start + 1
        var tag = "$"
        while i < chars.count, chars[i] != "$" {
            let c = chars[i]
            guard c.isLetter || c.isNumber || c == "_" else { return nil }
            tag.append(c); i += 1
        }
        guard i < chars.count, chars[i] == "$" else { return nil }
        tag.append("$")
        return tag
    }

    private static func matches(_ chars: [Character], at start: Int, tag: String) -> Bool {
        let tagChars = Array(tag)
        guard start + tagChars.count <= chars.count else { return false }
        for (offset, tagChar) in tagChars.enumerated() where chars[start + offset] != tagChar { return false }
        return true
    }
}
