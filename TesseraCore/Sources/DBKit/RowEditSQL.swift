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
