import Foundation

/// One completion candidate: what to insert, what to show, and how to badge it.
/// Pure value type so the completion engine (and its tests) need no AppKit.
public struct SQLCompletionItem: Equatable, Sendable {
    public enum Kind: Sendable { case keyword, function, table, column, schema, join }

    /// A `tableName → alias` rewrite a JOIN completion carries, so existing
    /// `tableName.` qualifiers can be rebound to the new alias.
    public struct Rename: Equatable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    /// The text written into the editor (identifiers arrive pre-quoted if needed).
    public var insert: String
    /// The name shown in the popup (unquoted).
    public var label: String
    /// Grey annotation: a column's type + key badges, a table's schema, etc.
    public var detail: String?
    public var kind: Kind
    /// Where the caret lands after inserting, as characters back from the end of
    /// `insert` (0 = end). Lets `count()` drop the caret between its parentheses.
    public var caretOffset: Int
    /// Set when this item aliases a table (a JOIN snippet).
    public var renameQualifier: Rename?

    public init(insert: String, label: String, detail: String?, kind: Kind,
                caretOffset: Int = 0, renameQualifier: Rename? = nil) {
        self.insert = insert
        self.label = label
        self.detail = detail
        self.kind = kind
        self.caretOffset = caretOffset
        self.renameQualifier = renameQualifier
    }
}

/// Schema-aware SQL completion: given the editor text and caret, produces the
/// replace range and ranked candidates (keywords, tables, columns, smart JOIN
/// snippets), plus the qualifier rewrites that keep aliased references valid.
/// Entirely pure — no AppKit, no editor — so it is unit-testable in isolation.
public struct SQLCompletionEngine {
    private struct ColumnInfo {
        let name: String
        let type: String
        let isPrimaryKey: Bool
        let isNullable: Bool
        let isIndexed: Bool
        /// Single-column FK target (table, column), if this column references one.
        let references: (table: String, column: String)?
        /// A key/indexed column — ranked ahead of the rest in ON/WHERE positions.
        var isKey: Bool { isPrimaryKey || isIndexed || references != nil }
    }

    private struct TableInfo {
        let schema: String
        let name: String
        let columns: [ColumnInfo]
        let approximateRowCount: Int?
    }

    private let dialect: any SQLDialect
    private let allTables: [TableInfo]
    private let tableByLower: [String: TableInfo]
    private let tablesBySchemaLower: [String: [TableInfo]]
    private let schemaNames: [String]

    /// `engine` selects the dialect (keywords, quoting, schema layer); Postgres
    /// stands in until a connection is chosen.
    public init(schema: DatabaseTree?, engine: DatabaseKind?) {
        self.dialect = (engine ?? .postgres).dialect
        var all: [TableInfo] = []
        var byLower: [String: TableInfo] = [:]
        var bySchema: [String: [TableInfo]] = [:]
        var names: [String] = []
        for namespace in schema?.schemas ?? [] {
            names.append(namespace.name)
            for table in namespace.tables {
                let indexed = Set(table.indexes.flatMap(\.columns).map { $0.lowercased() })
                let info = TableInfo(schema: namespace.name, name: table.name,
                                     columns: table.columns.map {
                                         ColumnInfo(name: $0.name, type: $0.dataType,
                                                    isPrimaryKey: $0.isPrimaryKey,
                                                    isNullable: $0.isNullable,
                                                    isIndexed: $0.isPrimaryKey || indexed.contains($0.name.lowercased()),
                                                    references: $0.references.map { ($0.table, $0.column) })
                                     },
                                     approximateRowCount: table.approximateRowCount)
                all.append(info)
                byLower[table.name.lowercased()] = info
                bySchema[namespace.name.lowercased(), default: []].append(info)
            }
        }
        self.allTables = all
        self.tableByLower = byLower
        self.tablesBySchemaLower = bySchema
        self.schemaNames = names
    }

    // MARK: Entry points

    /// The replace range and candidates for `caret` in `text`. Returns an empty
    /// list (and a zero-length range) inside a string literal or at the very start.
    public func complete(text: String, caret: Int, forced: Bool) -> (range: NSRange, items: [SQLCompletionItem]) {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length,
              !SQLText.isInsideStringLiteral(ns.substring(to: caret)) else {
            return (NSRange(location: caret, length: 0), [])
        }
        let range = SQLText.identifierRange(in: text, caret: caret)
        let partial = range.length > 0 ? ns.substring(with: range) : ""
        let before = ns.substring(to: range.location)
        let (override, items) = completionItems(partial: partial, before: before,
                                                range: range, fullText: text, forced: forced)
        return (override ?? range, items)
    }

    /// Rewrites `from.` qualifiers to `to.` within the statement at `caret`,
    /// skipping any inside `excluding` (the just-inserted text). Returns the new
    /// text and adjusted caret, or nil when nothing changes.
    public func rename(text: String, from: String, to: String,
                       caret: Int, excluding: NSRange) -> (text: String, caret: Int)? {
        guard from.lowercased() != to.lowercased() else { return nil }
        let ns = text as NSString
        let scope = SQLStatements.statementNSRange(sql: text, utf16Cursor: caret)
            ?? NSRange(location: 0, length: ns.length)
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from) + "(?=\\.)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let targets = regex.matches(in: text, range: scope)
            .map(\.range)
            .filter { NSIntersectionRange($0, excluding).length == 0 }
        guard !targets.isEmpty else { return nil }
        var newCaret = caret
        let mutable = NSMutableString(string: text)
        // Back-to-front so earlier ranges stay valid; shift the caret for edits ahead of it.
        for range in targets.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: to)
            if range.location < newCaret { newCaret += (to as NSString).length - range.length }
        }
        let updated = mutable as String
        guard updated != text else { return nil }
        return (updated, max(0, min(newCaret, (updated as NSString).length)))
    }

    /// Aliases defined in the statement at `caret` whose full-name references should
    /// now be rewritten (`from action a` ⇒ rewrite `action.` to `a.`). Skips an
    /// alias whose token the caret is still on, so it doesn't fire mid-typing.
    public func pendingAliasRewrites(text: String, caret: Int) -> [SQLCompletionItem.Rename] {
        let ns = text as NSString
        let scope = SQLStatements.statementNSRange(sql: text, utf16Cursor: caret)
            ?? NSRange(location: 0, length: ns.length)
        return aliasDefinitions(in: text, scope: scope)
            .filter { $0.alias.lowercased() != $0.table.lowercased() && caret != $0.end }
            .map { SQLCompletionItem.Rename(from: $0.table, to: $0.alias) }
    }

    // MARK: Keyword pool

    /// Keywords every supported dialect understands.
    private static let commonKeywords: [String] = [
        "SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN",
        "GROUP BY", "ORDER BY", "LIMIT", "OFFSET", "INSERT INTO", "VALUES", "UPDATE",
        "SET", "DELETE FROM", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT", "IN", "LIKE",
        "BETWEEN", "IS NULL", "IS NOT NULL", "ASC", "DESC", "HAVING", "UNION", "CASE",
        "WHEN", "THEN", "ELSE", "END", "EXISTS", "COUNT(", "SUM(", "AVG(", "MIN(",
        "MAX(", "COALESCE(", "CAST(", "NOW()",
    ]

    private var keywordPool: [String] { Self.commonKeywords + dialect.completionKeywords }

    // MARK: Statement context

    private static let aliasRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(from|join|update|into)\s+([`"]?[\w$]+[`"]?(?:\.[`"]?[\w$]+[`"]?)?)(?:\s+(?:as\s+)?([A-Za-z_][\w$]*))?"#)
    /// Words that can follow a table reference but are never its alias.
    private static let aliasStopWords: Set<String> = [
        "where", "join", "left", "right", "inner", "outer", "cross", "full", "natural",
        "on", "using", "group", "order", "limit", "offset", "set", "having", "union",
        "values", "returning", "for", "window", "fetch", "as", "straight_join",
    ]
    /// CTE names (`WITH x AS (…)`) so the query's own derived tables are treated as
    /// referenceable — columnless placeholders, since their columns are unknown.
    private static let cteRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:\bwith\b|,)\s+([`"]?[A-Za-z_][\w$]*[`"]?)\s+as\s*\("#)

    private func cteTables(_ text: String) -> [TableInfo] {
        let ns = text as NSString
        var result: [TableInfo] = []
        var seen: Set<String> = []
        Self.cteRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let name = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
            guard tableByLower[name.lowercased()] == nil, seen.insert(name.lowercased()).inserted else { return }
            result.append(TableInfo(schema: "", name: name, columns: [], approximateRowCount: nil))
        }
        return result
    }

    /// Tables referenced by the SQL being written, plus alias → table mappings.
    /// `extra` adds query-local tables (CTEs) to the lookup so `FROM my_cte c` resolves.
    private func statementContext(_ text: String, extra: [TableInfo] = [])
        -> (tables: [TableInfo], aliases: [String: TableInfo]) {
        var lookup = tableByLower
        for table in extra { lookup[table.name.lowercased()] = table }
        var tables: [TableInfo] = []
        var seen: Set<String> = []
        var aliases: [String: TableInfo] = [:]
        let ns = text as NSString
        Self.aliasRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let rawTable = ns.substring(with: match.range(at: 2))
            let cleaned = rawTable.replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "\"", with: "")
            let tableName = cleaned.split(separator: ".").last.map(String.init) ?? cleaned
            guard let info = lookup[tableName.lowercased()] else { return }
            if seen.insert(info.name.lowercased()).inserted { tables.append(info) }
            if match.range(at: 3).location != NSNotFound {
                let alias = ns.substring(with: match.range(at: 3)).lowercased()
                if !Self.aliasStopWords.contains(alias) { aliases[alias] = info }
            }
        }
        return (tables, aliases)
    }

    /// `from|join|… table alias` definitions in `scope`, with the alias token's end
    /// offset (so a still-being-typed alias can be left alone).
    private func aliasDefinitions(in text: String, scope: NSRange)
        -> [(table: String, alias: String, end: Int)] {
        let ns = text as NSString
        var out: [(table: String, alias: String, end: Int)] = []
        Self.aliasRegex.enumerateMatches(in: text, range: scope) { match, _, _ in
            guard let match, match.range(at: 3).location != NSNotFound else { return }
            let alias = ns.substring(with: match.range(at: 3))
            guard !Self.aliasStopWords.contains(alias.lowercased()) else { return }
            let rawTable = ns.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
            let table = rawTable.split(separator: ".").last.map(String.init) ?? rawTable
            out.append((table, alias, match.range(at: 3).location + match.range(at: 3).length))
        }
        return out
    }

    // MARK: Candidates

    private static let tableContextKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"]

    private func completionItems(partial: String, before: String, range: NSRange,
                                 fullText: String, forced: Bool) -> (NSRange?, [SQLCompletionItem]) {
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctes = cteTables(fullText)
        let context = statementContext(fullText, extra: ctes)
        // (candidate, priority) — lower priority sorts first within equal rank.
        var pool: [(item: SQLCompletionItem, priority: Int)] = []

        if trimmed.hasSuffix(".") {
            let qualifier = Self.lastIdentifier(in: String(trimmed.dropLast())).lowercased()
            // "1." is a decimal literal being typed, not a qualified reference.
            guard let first = qualifier.first, !first.isNumber else { return (nil, []) }
            if let info = context.aliases[qualifier] {
                // Qualifier is already an alias — its columns as-is.
                pool = info.columns.map { (columnItem($0), 0) }
            } else if let info = tableByLower[qualifier] {
                // Qualifier is a table name. If the query aliased that table, a bare
                // `table.col` is invalid SQL — rewrite it to `alias.col`, pulling the
                // `table.` prefix into the replaced range.
                if before.hasSuffix("."), let alias = aliasName(for: info, in: context.aliases),
                   let expanded = Self.qualifierRange(before: before, partialLength: range.length) {
                    // Return directly so an already-complete `object.id` still rewrites —
                    // the shared fully-typed guard would suppress it.
                    let q = partial.lowercased()
                    let columns = info.columns.filter {
                        q.isEmpty || $0.name.lowercased().contains(q) || Self.matchRank($0.name, query: q) != nil
                    }
                    return (expanded, columns.map { columnItem($0, qualifiedBy: alias) })
                }
                pool = info.columns.map { (columnItem($0), 0) }
            } else if dialect.hasSchemaLayer, let tables = tablesBySchemaLower[qualifier] {
                // In MySQL a "schema" is the database itself — no schema. prefix.
                pool = tables.map { (tableItem($0, detail: nil), 0) }
            } else {
                pool = contextColumnPool(context, fallbackToAll: true)
            }
        } else if Self.lastToken(in: before).uppercased() == "ON", !context.tables.isEmpty {
            // Right after a JOIN's ON: offer the foreign-key equality first, then the
            // columns of the referenced tables for a manual condition.
            pool = joinConditionPool(context)
            pool += contextColumnPool(context, fallbackToAll: false, keysFirst: true)
        } else if Self.lastToken(in: before).uppercased() == "JOIN" {
            // After JOIN: tables that link to one already in the query rank first,
            // pre-written as a full `table alias ON …` snippet; the rest follow as
            // `table alias`.
            pool = joinTablePool(context, extra: ctes)
            if dialect.hasSchemaLayer {
                pool += schemaNames.map { (schemaItem($0), 3) }
            }
        } else if Self.tableContextKeywords.contains(Self.lastToken(in: before).uppercased()) {
            pool = (allTables + ctes).map { (tableItem($0, detail: tableDetail($0)), 0) }
            if dialect.hasSchemaLayer {
                // Only a real schema layer is worth qualifying with.
                pool += schemaNames.map { (schemaItem($0), 1) }
            }
        } else {
            // Free position: don't pop up on every space — only with a prefix typed,
            // or when explicitly asked (⌃Space).
            guard !partial.isEmpty || forced else { return (nil, []) }
            pool = contextColumnPool(context, fallbackToAll: false)
            pool += (allTables + ctes).map { (tableItem($0, detail: tableDetail($0)), 2) }
            pool += keywordPool.map { (keywordItem($0, query: partial), 3) }
            pool += globalColumnPool(excluding: context)
            // `SELECT` with the referenced tables known: offer to expand into the
            // full column list.
            if Self.lastToken(in: before).uppercased() == "SELECT",
               let expansion = allColumnsItem(context) {
                pool.insert((expansion, 0), at: 0)
            }
        }

        let query = partial.lowercased()
        // A fully typed name means the user is done — hide the popup so Return makes a
        // newline again instead of committing some cousin candidate. JOIN snippets are
        // exempt: their label is the table name but they insert a whole `alias ON …`.
        if !query.isEmpty,
           pool.contains(where: { $0.item.label.lowercased() == query && $0.item.kind != .join }) {
            return (nil, [])
        }
        var seen: Set<String> = []
        let items = pool
            .compactMap { entry -> (SQLCompletionItem, Int, Int)? in
                guard let rank = Self.matchRank(entry.item.label, query: query) else { return nil }
                return (entry.item, rank, entry.priority)
            }
            .sorted { ($0.1, $0.2, $0.0.label.lowercased()) < ($1.1, $1.2, $1.0.label.lowercased()) }
            .compactMap { entry in
                seen.insert(entry.0.label.lowercased() + "\u{1}" + (entry.0.detail ?? "")).inserted
                    ? entry.0 : nil
            }
            .prefix(50)
            .map { $0 }
        return (nil, items)
    }

    /// Columns of the tables the statement references (priority 0), annotated with
    /// their type; falls back to every column when asked. `keysFirst` floats
    /// PK/FK/indexed columns above the rest (for ON/WHERE), and columns whose name
    /// appears in more than one referenced table are inserted alias-qualified.
    private func contextColumnPool(_ context: (tables: [TableInfo], aliases: [String: TableInfo]),
                                   fallbackToAll: Bool,
                                   keysFirst: Bool = false) -> [(item: SQLCompletionItem, priority: Int)] {
        let usingFallback = context.tables.isEmpty && fallbackToAll
        let tables = usingFallback ? allTables : context.tables
        var nameCounts: [String: Int] = [:]
        if !usingFallback {
            for info in tables { for column in info.columns { nameCounts[column.name.lowercased(), default: 0] += 1 } }
        }
        return tables.flatMap { info -> [(item: SQLCompletionItem, priority: Int)] in
            let qualifier = usingFallback ? nil : qualifier(for: info, aliases: context.aliases)
            return info.columns.map { column in
                let ambiguous = (nameCounts[column.name.lowercased()] ?? 0) > 1
                let item = columnItem(column, qualifiedBy: ambiguous ? qualifier : nil)
                let priority = keysFirst && !column.isKey ? 1 : 0
                return (item, priority)
            }
        }
    }

    /// Columns of every *other* table (priority 4), annotated with their table.
    private func globalColumnPool(
        excluding excluded: (tables: [TableInfo], aliases: [String: TableInfo])
    ) -> [(item: SQLCompletionItem, priority: Int)] {
        let excludedNames = Set(excluded.tables.map { $0.name.lowercased() })
        return allTables
            .filter { !excludedNames.contains($0.name.lowercased()) }
            .flatMap { info in
                info.columns.map { (columnItem($0, owningTable: info.name), 4) }
            }
    }

    // MARK: Smart JOIN

    /// Foreign-key equalities linking `candidate` to `existing`, both directions.
    private func joinLinks(_ candidate: TableInfo, _ existing: TableInfo) -> [(String, String)] {
        var links: [(String, String)] = []
        for column in candidate.columns {
            if let ref = column.references, ref.table.lowercased() == existing.name.lowercased() {
                links.append((column.name, ref.column))
            }
        }
        for column in existing.columns {
            if let ref = column.references, ref.table.lowercased() == candidate.name.lowercased() {
                links.append((ref.column, column.name))
            }
        }
        return links
    }

    /// A short alias from the table's initials (`order_items` → `oi`), disambiguated
    /// against `used` by appending a number (`o`, `o2`, …).
    private func tableAlias(for table: TableInfo, used: Set<String>) -> String {
        let parts = table.name.lowercased().split(whereSeparator: { $0 == "_" })
        var base = String(parts.compactMap(\.first))
        if base.isEmpty { base = String(table.name.lowercased().prefix(1)) }
        if base.isEmpty { base = "t" }
        guard used.contains(base) else { return base }
        var suffix = 2
        while used.contains("\(base)\(suffix)") { suffix += 1 }
        return "\(base)\(suffix)"
    }

    /// How an already-referenced table is written in a condition: its alias if it has
    /// one in the query, otherwise its bare name.
    private func qualifier(for table: TableInfo, aliases: [String: TableInfo]) -> String {
        for (alias, info) in aliases where info.name.lowercased() == table.name.lowercased() {
            return alias
        }
        return table.name
    }

    /// The alias the query gave `table`, if any — so a bare `object.` reference to an
    /// aliased table can be rewritten to `o.`.
    private func aliasName(for table: TableInfo, in aliases: [String: TableInfo]) -> String? {
        for (alias, info) in aliases where info.name.lowercased() == table.name.lowercased() {
            return alias
        }
        return nil
    }

    /// The range covering `qualifier.<partial>` ending at the caret. `before` ends
    /// at the dot; the partial is what was typed after it.
    private static func qualifierRange(before: String, partialLength: Int) -> NSRange? {
        let ns = before as NSString
        guard ns.hasSuffix(".") else { return nil }
        let qLen = (lastIdentifier(in: String(before.dropLast())) as NSString).length
        let start = ns.length - 1 - qLen
        guard qLen > 0, start >= 0 else { return nil }
        return NSRange(location: start, length: qLen + 1 + partialLength)
    }

    /// Tables offered after `JOIN`. FK-linked candidates come first, pre-written as a
    /// full `table alias ON …` snippet; the rest insert `table alias`.
    private func joinTablePool(_ context: (tables: [TableInfo], aliases: [String: TableInfo]),
                               extra: [TableInfo] = [])
        -> [(item: SQLCompletionItem, priority: Int)] {
        var pool: [(item: SQLCompletionItem, priority: Int)] = []
        let used = Set(context.aliases.keys)
        var linked: Set<String> = []
        for candidate in allTables {
            for existing in context.tables {
                let links = joinLinks(candidate, existing)
                guard !links.isEmpty else { continue }
                linked.insert(candidate.name.lowercased())
                let alias = tableAlias(for: candidate, used: used)
                // Aliasing the table invalidates any `table.` already written.
                let rename = alias.lowercased() != candidate.name.lowercased()
                    ? SQLCompletionItem.Rename(from: candidate.name, to: alias) : nil
                let rhs = qualifier(for: existing, aliases: context.aliases)
                let condition = links
                    .map { "\(alias).\(quoteIfNeeded($0.0)) = \(rhs).\(quoteIfNeeded($0.1))" }
                    .joined(separator: " AND ")
                let insert = "\(quoteIfNeeded(candidate.name)) \(alias) ON \(condition)"
                pool.append((SQLCompletionItem(insert: insert, label: candidate.name,
                                               detail: "\(alias) ON \(condition)", kind: .join,
                                               renameQualifier: rename), 0))
                // When every linked column shares its name, `USING (…)` is tidier.
                if links.allSatisfy({ $0.0.lowercased() == $0.1.lowercased() }) {
                    let cols = links.map { quoteIfNeeded($0.0) }.joined(separator: ", ")
                    pool.append((SQLCompletionItem(insert: "\(quoteIfNeeded(candidate.name)) \(alias) USING (\(cols))",
                                                   label: candidate.name,
                                                   detail: "\(alias) USING (\(cols))", kind: .join,
                                                   renameQualifier: rename), 0))
                }
            }
        }
        for candidate in allTables + extra where !linked.contains(candidate.name.lowercased()) {
            let alias = tableAlias(for: candidate, used: used)
            let rename = alias.lowercased() != candidate.name.lowercased()
                ? SQLCompletionItem.Rename(from: candidate.name, to: alias) : nil
            pool.append((SQLCompletionItem(insert: "\(quoteIfNeeded(candidate.name)) \(alias)",
                                           label: candidate.name,
                                           detail: tableDetail(candidate), kind: .table,
                                           renameQualifier: rename), 1))
        }
        return pool
    }

    /// After `ON`, the FK equalities between the just-joined table (the last one
    /// referenced) and the earlier tables in the query.
    private func joinConditionPool(_ context: (tables: [TableInfo], aliases: [String: TableInfo]))
        -> [(item: SQLCompletionItem, priority: Int)] {
        guard let joined = context.tables.last else { return [] }
        let lhs = qualifier(for: joined, aliases: context.aliases)
        var pool: [(item: SQLCompletionItem, priority: Int)] = []
        for existing in context.tables.dropLast() {
            let links = joinLinks(joined, existing)
            guard !links.isEmpty else { continue }
            let rhs = qualifier(for: existing, aliases: context.aliases)
            let condition = links
                .map { "\(lhs).\(quoteIfNeeded($0.0)) = \(rhs).\(quoteIfNeeded($0.1))" }
                .joined(separator: " AND ")
            pool.append((SQLCompletionItem(insert: condition, label: condition,
                                           detail: "→ \(existing.name)", kind: .join), 0))
        }
        return pool
    }

    // MARK: Item builders

    private func keywordItem(_ keyword: String, query: String) -> SQLCompletionItem {
        let isFunction = keyword.hasSuffix("(") || keyword.hasSuffix(")")
        // Follow the case the user is typing: lowercase the keyword when they've typed
        // a lowercase prefix, otherwise keep the canonical uppercase.
        var text = !query.isEmpty && query == query.lowercased() ? keyword.lowercased() : keyword
        var caret = 0
        // An open-paren function auto-closes with the caret inside: count() → count(|)
        if text.hasSuffix("(") { text += ")"; caret = 1 }
        return SQLCompletionItem(insert: text, label: keyword, detail: nil,
                                 kind: isFunction ? .function : .keyword, caretOffset: caret)
    }

    /// Table annotation: its schema (only where schemas are a real layer) and an
    /// approximate row count when the driver reported one.
    private func tableDetail(_ info: TableInfo) -> String? {
        var parts: [String] = []
        if dialect.hasSchemaLayer, !info.schema.isEmpty { parts.append(info.schema) }
        if let count = info.approximateRowCount, count > 0 {
            parts.append("~\(Self.compactCount(count)) rows")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func compactCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    /// Expands `SELECT *` into the referenced tables' column list, qualified when
    /// more than one table is in play. nil until a table is referenced.
    private func allColumnsItem(_ context: (tables: [TableInfo], aliases: [String: TableInfo]))
        -> SQLCompletionItem? {
        guard !context.tables.isEmpty else { return nil }
        let multi = context.tables.count > 1
        let columns = context.tables.flatMap { info -> [String] in
            let prefix = multi ? qualifier(for: info, aliases: context.aliases) + "." : ""
            return info.columns.map { prefix + quoteIfNeeded($0.name) }
        }
        guard !columns.isEmpty else { return nil }
        return SQLCompletionItem(insert: columns.joined(separator: ", "),
                                 label: "∗ all columns", detail: "\(columns.count) columns", kind: .column)
    }

    private func tableItem(_ info: TableInfo, detail: String?) -> SQLCompletionItem {
        SQLCompletionItem(insert: quoteIfNeeded(info.name), label: info.name, detail: detail, kind: .table)
    }

    /// A column row. `owningTable` (for other-table columns) leads the annotation;
    /// `qualifiedBy` inserts `alias.column` when the name is ambiguous. The
    /// annotation badges PK / FK→target / NOT NULL.
    private func columnItem(_ column: ColumnInfo, owningTable: String? = nil,
                            qualifiedBy alias: String? = nil) -> SQLCompletionItem {
        let insert = alias.map { "\($0).\(quoteIfNeeded(column.name))" } ?? quoteIfNeeded(column.name)
        return SQLCompletionItem(insert: insert, label: column.name,
                                 detail: columnDetail(column, owningTable: owningTable), kind: .column)
    }

    private func columnDetail(_ column: ColumnInfo, owningTable: String?) -> String {
        // A column from another table: its table is the key fact — keep it short.
        if let owningTable { return "\(owningTable) · \(column.type)" }
        var parts: [String] = [column.type]
        if column.isPrimaryKey { parts.append("PK") }
        if let ref = column.references { parts.append("FK→\(ref.table)") }
        if !column.isNullable { parts.append("NOT NULL") }
        return parts.joined(separator: " · ")
    }

    private func schemaItem(_ name: String) -> SQLCompletionItem {
        SQLCompletionItem(insert: quoteIfNeeded(name), label: name, detail: nil, kind: .schema)
    }

    // MARK: Matching & quoting

    /// nil = no match; 0 = prefix, 1 = a word inside starts with it, 2 = substring,
    /// 3 = fuzzy (all query characters appear in order, e.g. `oid` → `order_id`).
    static func matchRank(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let lower = candidate.lowercased()
        if lower == query { return nil }   // already fully typed
        if lower.hasPrefix(query) { return 0 }
        if lower.split(whereSeparator: { $0 == "_" || $0 == " " }).dropFirst()
            .contains(where: { $0.hasPrefix(query) }) { return 1 }
        if lower.contains(query) { return 2 }
        return isSubsequence(query, of: lower) ? 3 : nil
    }

    /// Whether every character of `needle` occurs in `haystack` in order.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = needle.startIndex
        guard index != needle.endIndex else { return true }
        for character in haystack where character == needle[index] {
            index = needle.index(after: index)
            if index == needle.endIndex { return true }
        }
        return false
    }

    private func quoteIfNeeded(_ name: String) -> String { dialect.quoteIfNeeded(name) }

    private static func lastToken(in string: String) -> String {
        string.split(whereSeparator: { " \n\t,()".contains($0) }).last.map(String.init) ?? ""
    }

    private static func lastIdentifier(in string: String) -> String {
        let identifier = string.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return String(identifier.reversed())
    }
}
