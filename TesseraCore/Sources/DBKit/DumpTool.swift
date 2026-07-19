import Foundation

/// What part of a table/database to dump.
public struct DumpOptions: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case database
        case schema(String)
        case tables(schema: String, tables: [String])
    }

    public var scope: Scope
    public var includeStructure: Bool
    public var includeData: Bool

    public init(scope: Scope = .database, includeStructure: Bool = true, includeData: Bool = true) {
        self.scope = scope
        self.includeStructure = includeStructure
        self.includeData = includeData
    }
}

/// Builds command lines for the external `pg_dump` / `mysqldump` binaries. Pure and
/// unit-tested; the process is actually spawned by the app layer.
public enum DumpTool {
    /// The binary a given engine dumps with.
    public static func binaryName(for kind: DatabaseKind) -> String {
        kind == .postgres ? "pg_dump" : "mysqldump"
    }

    /// Directories searched for the binary (in order) when no explicit path is set.
    public static let searchDirectories: [String] = [
        "/opt/homebrew/bin",                                            // Homebrew (Apple silicon)
        "/usr/local/bin",                                              // Homebrew (Intel) / manual
        "/Applications/Postgres.app/Contents/Versions/latest/bin",     // Postgres.app
        "/usr/bin",
    ]

    /// Homebrew formula that provides the binary, for the "please install" hint.
    public static func installHint(for kind: DatabaseKind) -> String {
        switch kind {
        case .postgres: "brew install libpq   # provides pg_dump (then: brew link --force libpq)"
        case .mysql: "brew install mysql-client   # provides mysqldump"
        }
    }

    /// Arguments (excluding the binary path); dump content goes to the tool's stdout,
    /// which the caller redirects to the output file.
    public static func arguments(kind: DatabaseKind, host: String, port: Int, user: String,
                                 database: String, options: DumpOptions) -> [String] {
        switch kind {
        case .postgres: postgresArguments(host: host, port: port, user: user, database: database, options: options)
        case .mysql: mysqlArguments(host: host, port: port, user: user, database: database, options: options)
        }
    }

    /// Environment carrying the password (never passed on argv, which is world-readable).
    public static func environment(kind: DatabaseKind, password: String?) -> [String: String] {
        guard let password, !password.isEmpty else { return [:] }
        switch kind {
        case .postgres: return ["PGPASSWORD": password]
        case .mysql: return ["MYSQL_PWD": password]
        }
    }

    // MARK: - Per-engine argument builders

    private static func postgresArguments(host: String, port: Int, user: String,
                                          database: String, options: DumpOptions) -> [String] {
        var args = ["--host=\(host)", "--port=\(port)", "--username=\(user)", "--no-password", "--no-owner"]
        if options.includeStructure && !options.includeData { args.append("--schema-only") }
        if options.includeData && !options.includeStructure { args.append("--data-only") }
        switch options.scope {
        case .database:
            break
        case .schema(let schema):
            args.append("--schema=\(schema)")
        case .tables(let schema, let tables):
            for table in tables { args.append("--table=\(schema).\(table)") }
        }
        args.append(database)
        return args
    }

    private static func mysqlArguments(host: String, port: Int, user: String,
                                       database: String, options: DumpOptions) -> [String] {
        var args = ["--host=\(host)", "--port=\(port)", "--user=\(user)"]
        if options.includeStructure && !options.includeData { args.append("--no-data") }
        if options.includeData && !options.includeStructure { args.append("--no-create-info") }
        args.append(database)
        // For MySQL, schema == database; a schema scope is just the database itself.
        if case .tables(_, let tables) = options.scope { args.append(contentsOf: tables) }
        return args
    }
}
