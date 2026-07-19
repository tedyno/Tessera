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

    /// The major version from a server or `--version` string (e.g. "16.2" → 16,
    /// "8.0.35" → 8). The first integer in the string.
    public static func majorVersion(_ text: String) -> Int? {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    /// Directories searched for the binary (in order) when no explicit path is set.
    /// Includes the keg-only Homebrew paths for `libpq` / `mysql-client`, which aren't
    /// symlinked into `bin` unless the user runs `brew link`.
    public static let searchDirectories: [String] = [
        "/opt/homebrew/bin",                                            // Homebrew (Apple silicon)
        "/usr/local/bin",                                              // Homebrew (Intel) / manual
        "/opt/homebrew/opt/libpq/bin",                                // keg-only libpq (Apple silicon)
        "/usr/local/opt/libpq/bin",                                   // keg-only libpq (Intel)
        "/opt/homebrew/opt/mysql-client/bin",                         // keg-only mysql-client (Apple silicon)
        "/usr/local/opt/mysql-client/bin",                            // keg-only mysql-client (Intel)
        "/Applications/Postgres.app/Contents/Versions/latest/bin",     // Postgres.app
        "/usr/bin",
    ]

    /// Complete, copy-pasteable install instructions for the missing binary — enough
    /// for anyone to get it working, including the keg-only path to set by hand.
    public static func installHint(for kind: DatabaseKind) -> String {
        switch kind {
        case .postgres:
            """
            Install pg_dump — in Terminal, run:
              brew install libpq && brew link --force libpq
            Then Browse to it (or paste the path):
              /opt/homebrew/opt/libpq/bin/pg_dump   (Apple Silicon)
              /usr/local/opt/libpq/bin/pg_dump      (Intel)
            """
        case .mysql:
            """
            Install mysqldump — in Terminal, run:
              brew install mysql-client && brew link --force mysql-client
            Then Browse to it (or paste the path):
              /opt/homebrew/opt/mysql-client/bin/mysqldump   (Apple Silicon)
              /usr/local/opt/mysql-client/bin/mysqldump      (Intel)
            """
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
