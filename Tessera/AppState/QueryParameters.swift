import Foundation

/// Client-side named parameters (`:from`, `:user_id`) in hand-written SQL.
/// The scanner skips string literals, quoted identifiers, comments and
/// Postgres `::type` casts, so only real placeholders are picked up. Values
/// are substituted as literals before the SQL leaves the app — the server
/// never sees the `:name` syntax.
enum QueryParameters {
    /// Placeholder names in first-appearance order, deduplicated.
    static func names(in sql: String) -> [String] {
        var seen = Set<String>()
        return scan(sql) { _ in nil }.names.filter { seen.insert($0).inserted }
    }

    /// Replaces every placeholder with a literal from `values`.
    static func substitute(_ sql: String, values: [String: String]) -> String {
        scan(sql) { name in values[name].map(literal(for:)) }.output
    }

    /// Empty and "NULL" run as SQL NULL, numbers stay unquoted, everything
    /// else becomes a quoted (escaped) string literal.
    static func literal(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.uppercased() == "NULL" { return "NULL" }
        if Double(trimmed) != nil, trimmed.first?.isLetter != true {
            return trimmed
        }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// One pass over the SQL: copies it out, reporting each placeholder and
    /// splicing in the replacement (nil keeps the placeholder as written).
    private static func scan(_ sql: String,
                             replace: (String) -> String?) -> (output: String, names: [String]) {
        enum State { case normal, single, double, lineComment, blockComment }
        var output = ""
        var names: [String] = []
        var state = State.normal
        var previous: Character = " "
        var i = sql.startIndex

        func peek(_ index: String.Index) -> Character? {
            let next = sql.index(after: index)
            return next < sql.endIndex ? sql[next] : nil
        }

        while i < sql.endIndex {
            let c = sql[i]
            switch state {
            case .single:
                output.append(c)
                if c == "'" { state = .normal }
            case .double:
                output.append(c)
                if c == "\"" { state = .normal }
            case .lineComment:
                output.append(c)
                if c == "\n" { state = .normal }
            case .blockComment:
                output.append(c)
                if c == "/", previous == "*" { state = .normal }
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
                    state = .blockComment
                    output.append(c)
                } else if c == ":" {
                    if peek(i) == ":" {
                        // `::type` cast — copy both colons and move on.
                        output.append("::")
                        previous = ":"
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
                        previous = sql[sql.index(before: end)]
                        i = end
                        continue
                    }
                    output.append(c)
                } else {
                    output.append(c)
                }
            }
            previous = c
            i = sql.index(after: i)
        }
        return (output, names)
    }
}
