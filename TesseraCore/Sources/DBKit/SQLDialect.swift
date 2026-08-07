import Foundation

/// Everything about an engine that shapes the SQL we generate or suggest —
/// the strategy the UI consults instead of switching on `DatabaseKind` at every
/// call site. Connection behaviour stays in `DatabaseDriver`; per-feature UI
/// details (mascots, dump binaries) stay with their features, where an
/// exhaustive switch is a virtue: adding an engine makes the compiler walk you
/// through them.
public protocol SQLDialect: Sendable {
    /// Quotes one identifier so mixed-case / reserved names survive.
    func quote(_ identifier: String) -> String
    /// Whether `identifier` can appear unquoted (dialects disagree on what's
    /// "plain": Postgres folds unquoted names to lowercase, MySQL doesn't).
    func needsQuoting(_ identifier: String) -> Bool
    /// True when the engine has a real schema layer between database and table
    /// (only Postgres here — the MySQL family equates schema with database,
    /// SQLite has a single namespace).
    var hasSchemaLayer: Bool { get }
    /// INSERT for a row with no explicit values (all defaults).
    func emptyInsert(table: String) -> String
    /// Statement prefix producing a query plan. `executes` warns that the
    /// analyzing variant actually runs the statement.
    func explainPrefix(analyze: Bool) -> (prefix: String, executes: Bool)
    /// Statement prefix producing a plan the app can render as a tree, or nil
    /// when the engine has no such form for this variant (the caller falls back
    /// to `explainPrefix` and the raw grid). `executes` mirrors `explainPrefix`.
    func structuredExplain(analyze: Bool) -> (prefix: String, executes: Bool, format: ExplainPlanFormat)?
    /// SQL listing the server's databases for the switcher, or nil when the
    /// engine has nothing to switch between.
    var listDatabasesSQL: String? { get }
    /// Completion keywords beyond the common SQL core.
    var completionKeywords: [String] { get }
    /// Words that must be quoted when used as identifiers.
    var reservedWords: Set<String> { get }
}

public extension SQLDialect {
    /// Quotes only when needed — for generated SQL meant to read naturally.
    func quoteIfNeeded(_ identifier: String) -> String {
        needsQuoting(identifier) ? quote(identifier) : identifier
    }
}

/// How a structured (tree-parseable) plan comes back from the server.
public enum ExplainPlanFormat: Sendable, Equatable {
    /// One row / one cell containing a JSON document.
    case json
    /// SQLite's EXPLAIN QUERY PLAN rows: (id, parent, notused, detail).
    case sqliteQueryPlan
    /// MySQL's EXPLAIN ANALYZE indented TREE text — its only ANALYZE shape.
    case mysqlTree
}

public extension DatabaseKind {
    var dialect: any SQLDialect {
        switch self {
        case .postgres: PostgresDialect()
        case .mysql: MySQLDialect()
        case .mariadb: MariaDBDialect()
        case .sqlite: SQLiteDialect()
        }
    }
}

/// Reserved words shared across dialects — an approximation tuned for "would
/// this break as a bare column/table name", not a full grammar.
private let commonReserved: Set<String> = [
    "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "FULL", "INNER", "OUTER",
    "CROSS", "ON", "USING", "GROUP", "BY", "ORDER", "LIMIT", "OFFSET", "INSERT",
    "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "INDEX",
    "DROP", "ALTER", "ADD", "COLUMN", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT",
    "IN", "LIKE", "BETWEEN", "IS", "ASC", "DESC", "HAVING", "UNION", "ALL",
    "CASE", "WHEN", "THEN", "ELSE", "END", "WITH", "PRIMARY", "KEY", "FOREIGN",
    "REFERENCES", "DEFAULT", "CHECK", "CONSTRAINT", "EXISTS", "ANY", "SOME",
    "TO", "DO", "USER", "GRANT", "BOTH", "ONLY", "COLLATE", "CURRENT_DATE",
    "CURRENT_TIME", "CAST", "TRUE", "FALSE",
]

private func doubleQuote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func backtick(_ identifier: String) -> String {
    "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
}

// MARK: - PostgreSQL

public struct PostgresDialect: SQLDialect {
    public init() {}

    public func quote(_ identifier: String) -> String { doubleQuote(identifier) }

    public func needsQuoting(_ identifier: String) -> Bool {
        // Unquoted identifiers fold to lowercase — any capital needs quotes.
        identifier.range(of: "^[a-z_][a-z0-9_$]*$", options: .regularExpression) == nil
            || reservedWords.contains(identifier.uppercased())
    }

    public var hasSchemaLayer: Bool { true }

    public func emptyInsert(table: String) -> String {
        "INSERT INTO \(table) DEFAULT VALUES;"
    }

    public func explainPrefix(analyze: Bool) -> (prefix: String, executes: Bool) {
        analyze ? ("EXPLAIN ANALYZE ", true) : ("EXPLAIN ", false)
    }

    public func structuredExplain(analyze: Bool) -> (prefix: String, executes: Bool, format: ExplainPlanFormat)? {
        analyze ? ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ", true, .json)
                : ("EXPLAIN (FORMAT JSON) ", false, .json)
    }

    public var listDatabasesSQL: String? {
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
    }

    public var completionKeywords: [String] {
        ["ILIKE", "RETURNING", "ON CONFLICT", "DO NOTHING", "DO UPDATE SET",
         "DISTINCT ON (", "STRING_AGG(", "ARRAY_AGG(", "JSON_AGG(", "JSONB_AGG(",
         "GENERATE_SERIES(", "DATE_TRUNC(", "INTERVAL", "FOR UPDATE"]
    }

    public var reservedWords: Set<String> {
        commonReserved.union(["ILIKE", "RETURNING", "LATERAL", "WINDOW", "OVER",
                              "PARTITION", "RECURSIVE", "TRUE", "FALSE"])
    }
}

// MARK: - MySQL

public struct MySQLDialect: SQLDialect {
    public init() {}

    public func quote(_ identifier: String) -> String { backtick(identifier) }

    public func needsQuoting(_ identifier: String) -> Bool {
        identifier.range(of: "^[A-Za-z_][A-Za-z0-9_$]*$", options: .regularExpression) == nil
            || reservedWords.contains(identifier.uppercased())
    }

    public var hasSchemaLayer: Bool { false }

    public func emptyInsert(table: String) -> String {
        "INSERT INTO \(table) () VALUES ();"
    }

    public func explainPrefix(analyze: Bool) -> (prefix: String, executes: Bool) {
        analyze ? ("EXPLAIN ANALYZE ", true) : ("EXPLAIN ", false)
    }

    public func structuredExplain(analyze: Bool) -> (prefix: String, executes: Bool, format: ExplainPlanFormat)? {
        // EXPLAIN ANALYZE emits indented TREE text (no JSON variant); it runs the
        // statement. Plain EXPLAIN has a JSON form the tree view parses directly.
        analyze ? ("EXPLAIN ANALYZE ", true, .mysqlTree)
                : ("EXPLAIN FORMAT=JSON ", false, .json)
    }

    public var listDatabasesSQL: String? {
        """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT IN
          ('information_schema', 'performance_schema', 'mysql', 'sys')
        ORDER BY schema_name
        """
    }

    public var completionKeywords: [String] {
        ["ON DUPLICATE KEY UPDATE", "REPLACE INTO", "GROUP_CONCAT(", "IFNULL(",
         "CURDATE()", "DATE_FORMAT(", "JSON_EXTRACT(", "STRAIGHT_JOIN", "AUTO_INCREMENT"]
    }

    public var reservedWords: Set<String> {
        commonReserved.union(["ROWS", "RANK", "DENSE_RANK", "ROW_NUMBER", "INTERVAL",
                              "GROUPS", "WINDOW", "LATERAL", "OVER", "PARTITION",
                              "RECURSIVE", "SYSTEM", "GENERATED", "STORED", "VIRTUAL",
                              "CUME_DIST", "NTILE", "LEAD", "LAG"])
    }
}

// MARK: - MariaDB (MySQL with a few of its own turns)

public struct MariaDBDialect: SQLDialect {
    private let base = MySQLDialect()
    public init() {}

    public func quote(_ identifier: String) -> String { base.quote(identifier) }
    public func needsQuoting(_ identifier: String) -> Bool {
        // Not delegated: the base would consult MySQL's reserved words and skip
        // the ones MariaDB adds (RETURNING).
        identifier.range(of: "^[A-Za-z_][A-Za-z0-9_$]*$", options: .regularExpression) == nil
            || reservedWords.contains(identifier.uppercased())
    }
    public var hasSchemaLayer: Bool { base.hasSchemaLayer }
    public func emptyInsert(table: String) -> String { base.emptyInsert(table: table) }
    public var listDatabasesSQL: String? { base.listDatabasesSQL }
    public var reservedWords: Set<String> { base.reservedWords.union(["RETURNING"]) }

    public func explainPrefix(analyze: Bool) -> (prefix: String, executes: Bool) {
        // MariaDB has no EXPLAIN ANALYZE; ANALYZE <statement> is its equivalent.
        analyze ? ("ANALYZE ", true) : ("EXPLAIN ", false)
    }

    public func structuredExplain(analyze: Bool) -> (prefix: String, executes: Bool, format: ExplainPlanFormat)? {
        analyze ? ("ANALYZE FORMAT=JSON ", true, .json) : ("EXPLAIN FORMAT=JSON ", false, .json)
    }

    public var completionKeywords: [String] {
        base.completionKeywords + ["RETURNING"]
    }
}

// MARK: - SQLite

public struct SQLiteDialect: SQLDialect {
    public init() {}

    public func quote(_ identifier: String) -> String { doubleQuote(identifier) }

    public func needsQuoting(_ identifier: String) -> Bool {
        // Case-preserving and case-insensitive: only odd characters or reserved
        // words force quotes.
        identifier.range(of: "^[A-Za-z_][A-Za-z0-9_$]*$", options: .regularExpression) == nil
            || reservedWords.contains(identifier.uppercased())
    }

    public var hasSchemaLayer: Bool { false }

    public func emptyInsert(table: String) -> String {
        "INSERT INTO \(table) DEFAULT VALUES;"
    }

    public func explainPrefix(analyze: Bool) -> (prefix: String, executes: Bool) {
        // One plan form; EXPLAIN QUERY PLAN never executes the statement.
        ("EXPLAIN QUERY PLAN ", false)
    }

    public func structuredExplain(analyze: Bool) -> (prefix: String, executes: Bool, format: ExplainPlanFormat)? {
        // Same single form as explainPrefix; the id/parent rows assemble into a tree.
        ("EXPLAIN QUERY PLAN ", false, .sqliteQueryPlan)
    }

    public var listDatabasesSQL: String? { nil }   // one file, one database

    public var completionKeywords: [String] {
        ["PRAGMA", "VACUUM", "AUTOINCREMENT", "WITHOUT ROWID", "GLOB", "RETURNING",
         "ON CONFLICT", "IFNULL(", "strftime(", "json_extract(", "GROUP_CONCAT(",
         "RANDOM()", "INSERT OR REPLACE INTO", "INSERT OR IGNORE INTO"]
    }

    public var reservedWords: Set<String> {
        commonReserved.union(["AUTOINCREMENT", "GLOB", "PRAGMA", "VACUUM", "ATTACH",
                              "DETACH", "REINDEX", "ROWID"])
    }
}
