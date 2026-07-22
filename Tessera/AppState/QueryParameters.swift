import Foundation

/// Client-side named parameters (`:from`, `:user_id`) in hand-written SQL.
/// The scanner skips string literals (including dollar-quoted bodies), quoted
/// identifiers, comments (nested, per Postgres) and `::type` casts, so only
/// real placeholders are picked up. Values are substituted as literals before
/// the SQL leaves the app — the server never sees the `:name` syntax.
///
/// `backslashEscapes` mirrors the engine: MySQL treats `\'` as an escaped
/// quote inside strings (and needs backslashes doubled in literals); Postgres
/// with standard_conforming_strings does not.
enum QueryParameters {
    /// Placeholder names in first-appearance order, deduplicated.
    static func names(in sql: String, backslashEscapes: Bool = false) -> [String] {
        var seen = Set<String>()
        return scan(sql, backslashEscapes: backslashEscapes) { _ in nil }
            .names.filter { seen.insert($0).inserted }
    }

    /// Replaces every placeholder with a literal from `values`.
    static func substitute(_ sql: String, values: [String: String],
                           backslashEscapes: Bool = false) -> String {
        scan(sql, backslashEscapes: backslashEscapes) { name in
            values[name].map { literal(for: $0, backslashEscapes: backslashEscapes) }
        }.output
    }

    /// Empty and "NULL" run as SQL NULL, plain numbers stay unquoted,
    /// everything else becomes a quoted (escaped) string literal.
    static func literal(for value: String, backslashEscapes: Bool = false) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.uppercased() == "NULL" { return "NULL" }
        // Strict SQL-number shape — `Double()` would also wave through
        // strtod spellings like "-inf", "0x1F" or "1e999".
        if trimmed.wholeMatch(of: /[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/) != nil {
            return trimmed
        }
        var escaped = value
        if backslashEscapes {
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        }
        escaped = escaped.replacingOccurrences(of: "'", with: "''")
        return "'" + escaped + "'"
    }

    /// One pass over the SQL: copies it out, reporting each placeholder and
    /// splicing in the replacement (nil keeps the placeholder as written).
    private static func scan(_ sql: String, backslashEscapes: Bool,
                             replace: (String) -> String?) -> (output: String, names: [String]) {
        enum State {
            case normal, single, double, lineComment
            case blockComment(depth: Int)
            case dollar(tag: String)
        }
        var output = ""
        var names: [String] = []
        var state = State.normal
        var i = sql.startIndex

        func peek(_ index: String.Index) -> Character? {
            let next = sql.index(after: index)
            return next < sql.endIndex ? sql[next] : nil
        }

        /// A `$tag$` opener at `index`, or nil (also matches plain `$$`).
        func dollarTag(at index: String.Index) -> String? {
            var j = sql.index(after: index)
            while j < sql.endIndex, sql[j].isLetter || sql[j].isNumber || sql[j] == "_" {
                j = sql.index(after: j)
            }
            guard j < sql.endIndex, sql[j] == "$" else { return nil }
            return String(sql[index...j])
        }

        while i < sql.endIndex {
            let c = sql[i]
            switch state {
            case .single:
                output.append(c)
                if backslashEscapes, c == "\\", i < sql.index(before: sql.endIndex) {
                    // Copy the escaped character verbatim — `\'` must not
                    // close the string on MySQL.
                    let next = sql.index(after: i)
                    output.append(sql[next])
                    i = sql.index(after: next)
                    continue
                }
                if c == "'" { state = .normal }
            case .double:
                output.append(c)
                if c == "\"" { state = .normal }
            case .lineComment:
                output.append(c)
                if c == "\n" { state = .normal }
            case .blockComment(let depth):
                // Postgres nests block comments; track the depth.
                if c == "/", peek(i) == "*" {
                    output.append("/*")
                    state = .blockComment(depth: depth + 1)
                    i = sql.index(i, offsetBy: 2)
                    continue
                }
                if c == "*", peek(i) == "/" {
                    output.append("*/")
                    state = depth > 1 ? .blockComment(depth: depth - 1) : .normal
                    i = sql.index(i, offsetBy: 2)
                    continue
                }
                output.append(c)
            case .dollar(let tag):
                if sql[i...].hasPrefix(tag) {
                    output.append(tag)
                    i = sql.index(i, offsetBy: tag.count)
                    state = .normal
                    continue
                }
                output.append(c)
            case .normal:
                if c == "'" {
                    state = .single
                    output.append(c)
                } else if c == "\"" {
                    state = .double
                    output.append(c)
                } else if c == "-", peek(i) == "-" {
                    state = .lineComment
                    output.append(c)
                } else if c == "/", peek(i) == "*" {
                    output.append("/*")
                    state = .blockComment(depth: 1)
                    i = sql.index(i, offsetBy: 2)
                    continue
                } else if c == "$", let tag = dollarTag(at: i) {
                    output.append(tag)
                    i = sql.index(i, offsetBy: tag.count)
                    state = .dollar(tag: tag)
                    continue
                } else if c == ":" {
                    if peek(i) == ":" {
                        // `::type` cast — copy both colons and move on.
                        output.append("::")
                        i = sql.index(i, offsetBy: 2)
                        continue
                    }
                    let next = sql.index(after: i)
                    if next < sql.endIndex, sql[next].isLetter || sql[next] == "_" {
                        var end = next
                        while end < sql.endIndex,
                              sql[end].isLetter || sql[end].isNumber || sql[end] == "_" {
                            end = sql.index(after: end)
                        }
                        let name = String(sql[next..<end])
                        names.append(name)
                        output.append(replace(name) ?? ":\(name)")
                        i = end
                        continue
                    }
                    output.append(c)
                } else {
                    output.append(c)
                }
            }
            i = sql.index(after: i)
        }
        return (output, names)
    }
}
