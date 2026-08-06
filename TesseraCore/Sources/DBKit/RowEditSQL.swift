import Foundation

/// The single source table a result maps to, enabling in-place editing.
public struct EditSource: Equatable, Sendable {
    public var schema: String
    public var table: String
    public var primaryKeys: [String]
    /// Columns the database fills itself (serial/identity/AUTO_INCREMENT); inserts
    /// omit them and the grid shows a "(generated)" placeholder.
    public var autoIncrementColumns: [String]

    public init(schema: String, table: String, primaryKeys: [String], autoIncrementColumns: [String]) {
        self.schema = schema
        self.table = table
        self.primaryKeys = primaryKeys
        self.autoIncrementColumns = autoIncrementColumns
    }
}

/// Pure SQL generation for in-place grid edits: which results are editable, and the
/// UPDATE/DELETE/INSERT statements a set of pending changes commits to. No UI, no
/// live connection — just text, so it is exhaustively unit-testable.
public enum RowEditSQL {

    // MARK: Editable-source detection

    /// Whether `sql` is a plain single-table `SELECT *` that can be written back, and
    /// the table/keys it targets. Rejects joins, aggregates, custom projections, and
    /// anything but a leading `SELECT`. A primary key must be present in `columns` to
    /// target rows reliably; a keyless table falls back to matching all columns.
    public static func detectEditSource(sql: String, columns: [ColumnDescriptor],
                                        schema: DatabaseTree?) -> EditSource? {
        let upper = sql.uppercased()
        guard upper.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SELECT"),
              sql.range(of: #"(?i)\b(join|group\s+by|having|distinct|union)\b"#,
                        options: .regularExpression) == nil else { return nil }
        guard let selectRange = sql.range(of: #"(?i)\bselect\b"#, options: .regularExpression),
              let fromKeyword = sql.range(of: #"(?i)\bfrom\b"#, options: .regularExpression),
              selectRange.upperBound <= fromKeyword.lowerBound else { return nil }
        let projection = sql[selectRange.upperBound..<fromKeyword.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard projection == "*" || projection.range(of: #"^[`"\w]+\.\*$"#, options: .regularExpression) != nil
        else { return nil }
        guard let range = sql.range(of: #"(?i)\bfrom\s+([`"\w\.]+)"#, options: .regularExpression) else { return nil }
        let raw = sql[range].split(whereSeparator: { " \n\t".contains($0) }).last.map(String.init) ?? ""
        let cleaned = raw.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
        let parts = cleaned.split(separator: ".").map(String.init)
        guard let tableName = parts.last else { return nil }
        let schemaName = parts.count >= 2 ? parts[parts.count - 2] : nil

        var found: (namespace: String, table: String, columns: [SchemaColumn])?
        for namespace in schema?.schemas ?? [] {
            if let schemaName, namespace.name.caseInsensitiveCompare(schemaName) != .orderedSame { continue }
            if let table = namespace.tables.first(where: { $0.name.caseInsensitiveCompare(tableName) == .orderedSame }) {
                found = (namespace.name, table.name, table.columns)
                break
            }
        }
        guard let found else { return nil }
        let primaryKeys = found.columns.filter(\.isPrimaryKey).map(\.name)
        let autoIncrement = found.columns.filter(\.isAutoIncrement).map(\.name)
        let resultColumns = Set(columns.map(\.name))
        if !primaryKeys.isEmpty {
            guard primaryKeys.allSatisfy(resultColumns.contains) else { return nil }
        }
        return EditSource(schema: found.namespace, table: found.table,
                          primaryKeys: primaryKeys, autoIncrementColumns: autoIncrement)
    }

    // MARK: Projected columns (zero-row header recovery)

    /// Best-effort recovery of the columns a query returns, from the SQL text plus the
    /// schema — so a zero-row result whose driver couldn't report its shape (MySQL)
    /// still shows headers. `*` and `table.*` expand from the schema (the ordered
    /// concatenation of the FROM/JOIN tables' columns); an explicit list yields each
    /// item's output name — its alias, else the plain column name, else the expression
    /// text verbatim — with the type filled from the schema for a plain column and
    /// left blank otherwise. Returns nil only when a bare `*` can't be expanded (an
    /// unresolvable FROM) or there's no projection to read, so the caller falls back
    /// to a plain "No results" state rather than dropping columns.
    public static func projectedColumns(sql: String, schema: DatabaseTree?) -> [ColumnDescriptor]? {
        guard SQLText.leadingKeyword(sql) == "SELECT" else { return nil }
        let chars = Array(sql)
        let masked = maskStructure(sql)          // length-aligned with `chars`
        guard chars.count == masked.count, let selectEnd = firstWordEnd("select", in: masked) else { return nil }

        // Skip a leading DISTINCT / ALL quantifier so it isn't read as a column.
        var projStart = selectEnd
        if let w = nextWord(masked, from: projStart), w.word == "distinct" || w.word == "all" {
            projStart = w.end
        }
        let fromStart = topLevelKeyword(["from"], in: masked, from: projStart)
        let projEnd = fromStart ?? masked.count
        let items = topLevelSplitCommas(masked, from: projStart, to: projEnd)
            .map { String(chars[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }

        let from = fromTables(masked: masked, chars: chars, fromStart: fromStart, schema: schema)
        var out: [ColumnDescriptor] = []
        for item in items {
            if item == "*" {
                guard from.resolvable, !from.columns.isEmpty else { return nil }
                out.append(contentsOf: from.columns)
            } else if item.range(of: #"^[`"\w$.]+\.\*$"#, options: .regularExpression) != nil {
                // `qualifier.*` — the qualifier may be a table name, a FROM alias, or a
                // schema-qualified name (`public.users.*`); take the last segment.
                let qualifier = (unquote(String(item.dropLast(2))).split(separator: ".").last.map(String.init) ?? "")
                    .lowercased()
                if let cols = from.byQualifier[qualifier] {
                    out.append(contentsOf: cols)
                } else if let cols = resolveColumns(table: qualifier, schema: nil, in: schema) {
                    out.append(contentsOf: cols)
                } else { return nil }
            } else {
                out.append(projectionItem(item, typeByName: from.typeByName))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Name + best-effort type for one non-`*` projection item: its alias when it has
    /// one (`expr AS x`, or a trailing bare-identifier alias), otherwise the plain
    /// column name, otherwise the expression text verbatim. Type comes from the schema
    /// only for a plain column reference; expressions get a blank type.
    private static func projectionItem(_ item: String, typeByName: [String: String]) -> ColumnDescriptor {
        let masked = maskStructure(item)
        let chars = Array(item)
        let tokens = topLevelTokens(masked: masked, chars: chars)
        // `expr AS alias`
        if let asIndex = tokens.firstIndex(where: { $0.lowercased() == "as" }), asIndex + 1 < tokens.count {
            return ColumnDescriptor(name: unquote(tokens[asIndex + 1]),
                                    typeName: type(of: Array(tokens[0..<asIndex]), typeByName))
        }
        // Implicit alias: `expr alias`, where the token before the trailing identifier
        // isn't an operator (so `a + b` keeps `b`) and isn't a mid-expression keyword
        // like `and`/`is` (so `a is null` isn't split) — but `end` legitimately
        // terminates a CASE, so `case … end label` still yields `label`.
        if tokens.count >= 2, let last = tokens.last, isBareIdentifier(last), !isKeyword(last) {
            let prev = tokens[tokens.count - 2]
            if !isOperator(prev), !isKeyword(prev) || prev.lowercased() == "end" {
                return ColumnDescriptor(name: unquote(last),
                                        typeName: type(of: Array(tokens[0..<tokens.count - 1]), typeByName))
            }
        }
        // No alias: a plain column keeps its (unqualified) name; anything else is named
        // by its own text, whitespace-collapsed to read tidily.
        if tokens.count == 1, isColumnRef(tokens[0]) {
            let name = unquote(tokens[0]).split(separator: ".").last.map(String.init) ?? unquote(tokens[0])
            return ColumnDescriptor(name: name, typeName: typeByName[name.lowercased()] ?? "")
        }
        return ColumnDescriptor(name: item.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                                typeName: "")
    }

    /// The type of a plain single-column expression from the schema map, else blank.
    private static func type(of exprTokens: [String], _ typeByName: [String: String]) -> String {
        guard exprTokens.count == 1, isColumnRef(exprTokens[0]) else { return "" }
        let name = unquote(exprTokens[0]).split(separator: ".").last.map(String.init) ?? ""
        return typeByName[name.lowercased()] ?? ""
    }

    /// Ordered columns and a name→type map for the FROM/JOIN tables, and whether they
    /// all resolved (so a `*` may be expanded). A subquery/table-function in FROM, or
    /// any unknown table, makes it unresolvable.
    private static func fromTables(masked: [Character], chars: [Character], fromStart: Int?,
                                   schema: DatabaseTree?)
        -> (columns: [ColumnDescriptor], typeByName: [String: String],
            byQualifier: [String: [ColumnDescriptor]], resolvable: Bool) {
        let empty: (columns: [ColumnDescriptor], typeByName: [String: String],
                    byQualifier: [String: [ColumnDescriptor]], resolvable: Bool) = ([], [:], [:], false)
        guard let fromStart else { return empty }
        let start = fromStart + 4   // past "from" (always 4 chars — `topLevelKeyword` matched it exactly)
        let end = topLevelKeyword(["where", "group", "order", "limit", "having", "window",
                                   "for", "union", "intersect", "except"], in: masked, from: start) ?? masked.count

        // Pick the table token at each table position (start of FROM, after a comma, or
        // after a JOIN word) plus the alias that follows it; skip ON/USING conditions
        // and any parenthesised text. A `(` where a table is expected is a subquery we
        // can't resolve → the whole projection falls back to a plain "No results".
        enum State { case expectTable, afterTable, expectAlias, done }
        let modifiers: Set<String> = ["natural", "inner", "cross", "left", "right", "full", "outer"]
        var refs: [(table: String, alias: String?)] = []
        var state: State = .expectTable
        var depth = 0
        var i = start
        while i < end {
            let c = masked[i]
            if c == "(" {
                if state == .expectTable, depth == 0 { return empty }   // subquery in table position
                depth += 1; i += 1; continue
            }
            if c == ")" { if depth > 0 { depth -= 1 }; i += 1; continue }
            if depth == 0, c == "," { state = .expectTable; i += 1; continue }
            if depth == 0, isWordChar(c), i == start || !isWordChar(masked[i - 1]) {
                var j = i
                while j < end, isWordChar(masked[j]) || masked[j] == "." { j += 1 }
                let word = String(chars[i..<j])
                let lower = String(masked[i..<j]).lowercased()
                switch state {
                case .expectTable:
                    refs.append((word, nil)); state = .afterTable
                case .afterTable:
                    if lower == "join" || lower == "straight_join" { state = .expectTable }
                    else if lower == "as" { state = .expectAlias }
                    else if lower == "on" || lower == "using" { state = .done }
                    else if modifiers.contains(lower) { break }   // part of a JOIN clause
                    else { refs[refs.count - 1].alias = word; state = .done }
                case .expectAlias:
                    refs[refs.count - 1].alias = word; state = .done
                case .done:
                    if lower == "join" || lower == "straight_join" { state = .expectTable }
                }
                i = j; continue
            }
            i += 1
        }

        var columns: [ColumnDescriptor] = []
        var typeByName: [String: String] = [:]
        var byQualifier: [String: [ColumnDescriptor]] = [:]
        for ref in refs {
            let parts = unquote(ref.table).split(separator: ".").map(String.init)
            guard let tableName = parts.last,
                  let cols = resolveColumns(table: tableName, schema: parts.count >= 2 ? parts[parts.count - 2] : nil,
                                            in: schema)
            else { return empty }
            columns.append(contentsOf: cols)
            for col in cols where typeByName[col.name.lowercased()] == nil {
                typeByName[col.name.lowercased()] = col.typeName
            }
            byQualifier[tableName.lowercased()] = cols            // `table.*`
            if let alias = ref.alias { byQualifier[unquote(alias).lowercased()] = cols }   // `alias.*`
        }
        return (columns, typeByName, byQualifier, !columns.isEmpty)
    }

    /// A table's columns as descriptors, matched case-insensitively (and by schema
    /// when qualified). nil when the table isn't in the introspected schema.
    private static func resolveColumns(table: String, schema schemaName: String?,
                                       in schema: DatabaseTree?) -> [ColumnDescriptor]? {
        for namespace in schema?.schemas ?? [] {
            if let schemaName, namespace.name.caseInsensitiveCompare(schemaName) != .orderedSame { continue }
            if let found = namespace.tables.first(where: { $0.name.caseInsensitiveCompare(table) == .orderedSame }) {
                return found.columns.map { ColumnDescriptor(name: $0.name, typeName: $0.dataType) }
            }
        }
        return nil
    }

    // MARK: SQL scanning helpers (parenthesis / quote aware)

    /// `maskLiteralsAndComments` plus blanking of double-quoted / back-ticked
    /// identifier bodies, so structural scans (commas, parens, keywords) never trip
    /// over punctuation inside a string, comment, or quoted name. Length-preserving,
    /// so indices map back onto the original text.
    private static func maskStructure(_ sql: String) -> [Character] {
        var out = Array(SQLText.maskLiteralsAndComments(sql))
        var i = 0
        while i < out.count {
            let quote = out[i]
            guard quote == "\"" || quote == "`" else { i += 1; continue }
            i += 1
            while i < out.count {
                if out[i] == quote { i += 1; break }
                out[i] = " "; i += 1
            }
        }
        return out
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }

    /// End index of the first word in `masked` when it equals `word` (leading comments
    /// are already blanks); nil otherwise.
    private static func firstWordEnd(_ word: String, in masked: [Character]) -> Int? {
        var i = 0
        while i < masked.count, masked[i].isWhitespace { i += 1 }
        var j = i
        while j < masked.count, isWordChar(masked[j]) { j += 1 }
        return String(masked[i..<j]).lowercased() == word ? j : nil
    }

    /// The next word (lowercased) and its end index, skipping leading whitespace.
    private static func nextWord(_ masked: [Character], from start: Int) -> (word: String, end: Int)? {
        var i = start
        while i < masked.count, masked[i].isWhitespace { i += 1 }
        var j = i
        while j < masked.count, isWordChar(masked[j]) { j += 1 }
        guard j > i else { return nil }
        return (String(masked[i..<j]).lowercased(), j)
    }

    /// Start index of the first top-level (paren-depth 0) keyword in `words`.
    private static func topLevelKeyword(_ words: Set<String>, in masked: [Character], from start: Int) -> Int? {
        var i = start, depth = 0
        while i < masked.count {
            let c = masked[i]
            if c == "(" { depth += 1; i += 1; continue }
            if c == ")" { if depth > 0 { depth -= 1 }; i += 1; continue }
            if depth == 0, isWordChar(c), i == start || !isWordChar(masked[i - 1]) {
                var j = i
                while j < masked.count, isWordChar(masked[j]) { j += 1 }
                if words.contains(String(masked[i..<j]).lowercased()) { return i }
                i = j; continue
            }
            i += 1
        }
        return nil
    }

    /// Character ranges of the comma-separated segments in `[from, to)` at paren-depth 0.
    private static func topLevelSplitCommas(_ masked: [Character], from: Int, to: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var depth = 0, segStart = from, i = from
        while i < to {
            let c = masked[i]
            if c == "(" { depth += 1 }
            else if c == ")" { if depth > 0 { depth -= 1 } }
            else if c == ",", depth == 0 { ranges.append(segStart..<i); segStart = i + 1 }
            i += 1
        }
        ranges.append(segStart..<to)
        return ranges
    }

    /// Whitespace-separated tokens of an item at paren-depth 0 (a parenthesised group
    /// stays one token). Returned as their original text.
    private static func topLevelTokens(masked: [Character], chars: [Character]) -> [String] {
        var tokens: [String] = []
        var depth = 0, start = -1, i = 0
        func flush(_ end: Int) { if start >= 0 { tokens.append(String(chars[start..<end])); start = -1 } }
        while i < masked.count {
            let c = masked[i]
            if c == "(" { if start < 0 { start = i }; depth += 1 }
            else if c == ")" { if start < 0 { start = i }; if depth > 0 { depth -= 1 } }
            else if depth == 0, c.isWhitespace { flush(i) }
            else if start < 0 { start = i }
            i += 1
        }
        flush(masked.count)
        return tokens
    }

    private static func unquote(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
    }

    /// A plain column reference: `name` or `qualifier.name`, no call parentheses.
    private static func isColumnRef(_ token: String) -> Bool {
        !token.contains("(") &&
            token.range(of: #"^[`"]?[\w$]+[`"]?(\.[`"]?[\w$]+[`"]?)*$"#, options: .regularExpression) != nil
    }

    private static func isBareIdentifier(_ token: String) -> Bool {
        token.range(of: #"^[`"]?[A-Za-z_][\w$]*[`"]?$"#, options: .regularExpression) != nil
    }

    private static func isOperator(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { "+-*/%=<>!|&^~".contains($0) }
    }

    private static let expressionKeywords: Set<String> = [
        "as", "and", "or", "not", "is", "in", "like", "between", "case", "when", "then",
        "else", "end", "null", "true", "false", "asc", "desc", "distinct", "over", "using", "on",
    ]
    private static func isKeyword(_ token: String) -> Bool {
        expressionKeywords.contains(unquote(token).lowercased())
    }

    // MARK: Cell edit tracking

    /// Updates the pending edits for one cell of a fetched row, mirroring how the grid
    /// records a manual edit: an edit back to the original value (or a no-op NULL) is
    /// dropped, otherwise recorded. A `nil` inner value records "set to SQL NULL"
    /// (distinct from removing the key, which reverts the cell). Returns the new edits
    /// for that row, or nil when the row has none left.
    public static func applyingEdit(to rowEdits: [String: String?]?, column: String,
                                    newValue: String?, original: String?) -> [String: String?]? {
        var edits = rowEdits ?? [:]
        if let newValue {
            if original != nil, newValue == original {
                edits[column] = nil                     // edited back to original → drop
            } else {
                edits[column] = newValue
            }
        } else if original == nil {
            edits[column] = nil                         // already NULL → drop the no-op
        } else {
            edits.updateValue(nil, forKey: column)      // set to SQL NULL
        }
        return edits.isEmpty ? nil : edits
    }

    // MARK: Statement generation

    /// Qualified, quoted `schema.table` for the source.
    public static func qualifiedTable(_ source: EditSource, dialect: any SQLDialect) -> String {
        "\(dialect.quote(source.schema)).\(dialect.quote(source.table))"
    }

    /// The UPDATE/DELETE/INSERT statements for the pending changes, in commit order
    /// (deletes, then updates grouped by identical change-set, then inserts). Rows
    /// with identical edits collapse into a single `… WHERE pk IN (…)`; without a
    /// primary key the WHERE matches all selected columns.
    public static func statements(source: EditSource, result: QueryResult,
                                  edits: [Int: [String: String?]], deletes: Set<Int>,
                                  inserts: [[String: String]], dialect: any SQLDialect) -> [String] {
        let table = qualifiedTable(source, dialect: dialect)
        let keyColumns = source.primaryKeys.isEmpty ? result.columns.map(\.name) : source.primaryKeys
        var statements: [String] = []

        let deleteRows = deletes.sorted()
        if !deleteRows.isEmpty {
            for clause in whereClauses(rows: deleteRows, keyColumns: keyColumns, result: result, dialect: dialect) {
                statements.append("DELETE FROM \(table) WHERE \(clause);")
            }
        }

        for group in editGroups(edits, skipping: deletes) {
            let setClause = updateSetClause(group.changes, result: result, dialect: dialect)
            for clause in whereClauses(rows: group.rows, keyColumns: keyColumns, result: result, dialect: dialect) {
                statements.append("UPDATE \(table) SET \(setClause) WHERE \(clause);")
            }
        }

        for values in inserts {
            statements.append(insertStatement(table: table, values: values, source: source,
                                              result: result, dialect: dialect))
        }
        return statements
    }

    /// Pending updates grouped by identical change-set (rows deleted are skipped),
    /// ordered by their lowest row index — the grouping `statements` and the UI
    /// change panel share.
    public static func editGroups(_ edits: [Int: [String: String?]], skipping deletes: Set<Int>)
        -> [(changes: [String: String?], rows: [Int])] {
        var groups: [String: (changes: [String: String?], rows: [Int])] = [:]
        for (row, changes) in edits where !deletes.contains(row) {
            // "s"/"n" prefix keeps a cell set to NULL distinct from any real text.
            let key = changes.sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1}\($0.value.map { "s\($0)" } ?? "n")" }.joined(separator: "\u{2}")
            groups[key, default: (changes, [])].rows.append(row)
        }
        return groups.values
            .map { (changes: $0.changes, rows: $0.rows.sorted()) }
            .sorted { ($0.rows.min() ?? 0) < ($1.rows.min() ?? 0) }
    }

    /// `col = value, …` for an UPDATE, columns in name order.
    public static func updateSetClause(_ changes: [String: String?], result: QueryResult,
                                       dialect: any SQLDialect) -> String {
        changes.sorted { $0.key < $1.key }
            .map { "\(dialect.quote($0.key)) = \(literal($0.value, columnName: $0.key, result: result))" }
            .joined(separator: ", ")
    }

    /// A single `INSERT INTO …` (or the dialect's empty-row form). Auto-increment
    /// columns and columns the user never set are omitted so their defaults apply.
    public static func insertStatement(table: String, values: [String: String], source: EditSource,
                                       result: QueryResult, dialect: any SQLDialect) -> String {
        let autoInc = Set(source.autoIncrementColumns)
        let cols = result.columns.map(\.name).filter { !autoInc.contains($0) && values[$0] != nil }
        guard !cols.isEmpty else { return dialect.emptyInsert(table: table) }
        let colList = cols.map { dialect.quote($0) }.joined(separator: ", ")
        let valList = cols.map { literal(values[$0]!, columnName: $0, result: result) }.joined(separator: ", ")
        return "INSERT INTO \(table) (\(colList)) VALUES (\(valList));"
    }

    /// WHERE clauses for the given rows: one `col IN (…)` when the key is a single
    /// column with no NULLs, otherwise one AND-clause per row.
    public static func whereClauses(rows: [Int], keyColumns: [String], result: QueryResult,
                                    dialect: any SQLDialect) -> [String] {
        if keyColumns.count == 1, let name = keyColumns.first,
           let index = result.columns.firstIndex(where: { $0.name == name }) {
            let values = rows.compactMap { row -> String? in
                guard row < result.rows.count, index < result.rows[row].count,
                      let text = result.rows[row][index].text else { return nil }
                return literal(text, columnName: name, result: result)
            }
            if values.count == rows.count, !values.isEmpty {
                return ["\(dialect.quote(name)) IN (\(values.joined(separator: ", ")))"]
            }
        }
        return rows.map { rowWhere($0, keyColumns: keyColumns, result: result, dialect: dialect) }
    }

    private static func rowWhere(_ row: Int, keyColumns: [String], result: QueryResult,
                                 dialect: any SQLDialect) -> String {
        keyColumns.compactMap { name -> String? in
            guard let index = result.columns.firstIndex(where: { $0.name == name }),
                  row < result.rows.count, index < result.rows[row].count else { return nil }
            let text = result.rows[row][index].text
            return text == nil ? "\(dialect.quote(name)) IS NULL"
                               : "\(dialect.quote(name)) = \(literal(text!, columnName: name, result: result))"
        }.joined(separator: " AND ")
    }

    // MARK: Value literals

    /// A SQL literal for `value`: `NULL` for nil, unquoted for a numeric column whose
    /// text is actually a number (so `id = 3`, not `id = '3'`), quoted+escaped else.
    public static func literal(_ value: String?, columnName: String, result: QueryResult) -> String {
        guard let value else { return "NULL" }
        if let column = result.columns.first(where: { $0.name == columnName }),
           isNumericType(column.typeName), looksNumeric(value) {
            return value
        }
        return literal(value)
    }

    private static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func isNumericType(_ typeName: String) -> Bool {
        let names: Set<String> = [
            // Postgres (PostgresDataType descriptions)
            "SMALLINT", "INTEGER", "BIGINT", "REAL", "DOUBLE PRECISION", "NUMERIC", "DECIMAL", "OID",
            // MySQL (MySQLProtocol.DataType descriptions)
            "MYSQL_TYPE_TINY", "MYSQL_TYPE_SHORT", "MYSQL_TYPE_LONG", "MYSQL_TYPE_INT24",
            "MYSQL_TYPE_LONGLONG", "MYSQL_TYPE_FLOAT", "MYSQL_TYPE_DOUBLE",
            "MYSQL_TYPE_DECIMAL", "MYSQL_TYPE_NEWDECIMAL", "MYSQL_TYPE_YEAR",
        ]
        return names.contains(typeName.uppercased())
    }

    private static func looksNumeric(_ text: String) -> Bool {
        text.range(of: #"^-?\d+(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil
    }
}

/// Pure SQL generation for the data-view grid: the generated `SELECT *` (with
/// filter/sort/paging) and the header-click `ORDER BY` rewrite of a free-form query.
public enum DataViewSQL {
    /// One column of a header sort.
    public struct SortKey: Equatable, Sendable {
        public var column: String
        public var ascending: Bool
        public init(column: String, ascending: Bool) {
            self.column = column
            self.ascending = ascending
        }
    }

    /// The generated `SELECT * FROM schema.table` for a data view, folding in the
    /// filter, sort, and page limit. `unlimited` drops the paging cap (streamed export).
    public static func select(schema: String, table: String, filter: String,
                              sortOrder: [SortKey], limit: Int?, offset: Int?,
                              orderOverride: [String]?, unlimited: Bool, dialect: any SQLDialect) -> String {
        var sql = "SELECT * FROM \(dialect.quote(schema)).\(dialect.quote(table))"
        let filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty { sql += " WHERE \(filter)" }
        if !sortOrder.isEmpty {
            sql += " ORDER BY " + sortOrder
                .map { "\(dialect.quote($0.column)) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
        } else if let orderOverride, !orderOverride.isEmpty {
            sql += " ORDER BY " + orderOverride.map { dialect.quote($0) }.joined(separator: ", ")
        }
        if !unlimited {
            sql += " LIMIT \(limit ?? 0)"
            if let offset, offset > 0 { sql += " OFFSET \(offset)" }
        }
        return sql
    }

    /// Replaces the top-level `ORDER BY` of a full-table query (before any
    /// `LIMIT`/`OFFSET`/`;`). An empty `sortOrder` removes ordering. String-literal
    /// contents are ignored, so a WHERE value like `'a limit b'` is safe.
    public static func rewriteOrderBy(_ sql: String, sortOrder: [SortKey], dialect: any SQLDialect) -> String {
        var body = sql
        if let existing = topLevelRange(
            in: body, pattern: #"(?is)\s+ORDER\s+BY\s+.*?(?=(\s+LIMIT\b|\s+OFFSET\b|\s*;\s*$|$))"#) {
            body.removeSubrange(existing)
        }
        guard !sortOrder.isEmpty else { return body }
        let clause = " ORDER BY " + sortOrder
            .map { "\(dialect.quote($0.column)) \($0.ascending ? "ASC" : "DESC")" }
            .joined(separator: ", ")
        if let tail = topLevelRange(in: body, pattern: #"(?is)\s*(LIMIT\b|OFFSET\b|;\s*$)"#) {
            body.insert(contentsOf: clause, at: tail.lowerBound)
        } else {
            body += clause
        }
        return body
    }

    /// A regex match on `s`, searched against a copy with string-literal contents
    /// blanked out so SQL keywords inside `'…'` don't match. Length is preserved.
    static func topLevelRange(in s: String, pattern: String) -> Range<String.Index>? {
        let masked = maskStringLiterals(s)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(masked.startIndex..., in: masked)
        guard let match = regex.firstMatch(in: masked, range: range), match.range.length > 0 else { return nil }
        return Range(match.range, in: s)
    }

    /// Replaces each character inside a single-quoted literal with `x`, preserving the
    /// quotes and length (so ranges map back to the original 1:1).
    static func maskStringLiterals(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inQuote = false
        for character in s {
            if character == "'" {
                inQuote.toggle()
                out.append(character)
            } else {
                out.append(inQuote ? "x" : character)
            }
        }
        return out
    }
}
