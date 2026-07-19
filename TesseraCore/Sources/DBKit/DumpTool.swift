import Foundation

/// What and how to dump. `schemas`/`tables` empty means the whole database.
public struct DumpOptions: Sendable, Equatable {
    /// pg_dump output format; MySQL is always plain SQL.
    public enum Format: String, Sendable, Equatable { case plain, custom }

    public var schemas: [String]
    public var tables: [String]
    public var includeStructure: Bool
    public var includeData: Bool
    /// Emit DROP before CREATE (pg `--clean` / mysql `--add-drop-table`).
    public var dropBeforeCreate: Bool
    /// Make the drops `IF EXISTS` (pg `--if-exists`; implicit on MySQL).
    public var dropIfExists: Bool
    /// Include CREATE DATABASE (pg `--create` / mysql `--databases`).
    public var createDatabase: Bool
    /// Portable `INSERT` statements instead of COPY / extended inserts.
    public var useInsertStatements: Bool
    /// pg_dump format (plain SQL, or custom for pg_restore).
    public var format: Format
    /// Pipe the output through gzip (`.gz`). Not used with the custom format.
    public var gzip: Bool

    public init(schemas: [String] = [], tables: [String] = [],
                includeStructure: Bool = true, includeData: Bool = true,
                dropBeforeCreate: Bool = false, dropIfExists: Bool = false,
                createDatabase: Bool = false, useInsertStatements: Bool = false,
                format: Format = .plain, gzip: Bool = false) {
        self.schemas = schemas
        self.tables = tables
        self.includeStructure = includeStructure
        self.includeData = includeData
        self.dropBeforeCreate = dropBeforeCreate
        self.dropIfExists = dropIfExists
        self.createDatabase = createDatabase
        self.useInsertStatements = useInsertStatements
        self.format = format
        self.gzip = gzip
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
        args.append(options.format == .custom ? "--format=custom" : "--format=plain")
        if options.includeStructure && !options.includeData { args.append("--schema-only") }
        if options.includeData && !options.includeStructure { args.append("--data-only") }
        if options.dropBeforeCreate {
            args.append("--clean")
            if options.dropIfExists { args.append("--if-exists") }
        }
        if options.createDatabase { args.append("--create") }
        if options.useInsertStatements { args.append("--inserts") }
        for schema in options.schemas where !schema.isEmpty { args.append("--schema=\(schema)") }
        for table in options.tables where !table.isEmpty {
            let qualified = table.contains(".") ? table
                : (options.schemas.count == 1 ? "\(options.schemas[0]).\(table)" : table)
            args.append("--table=\(qualified)")
        }
        args.append(database)
        return args
    }

    private static func mysqlArguments(host: String, port: Int, user: String,
                                       database: String, options: DumpOptions) -> [String] {
        var args = ["--host=\(host)", "--port=\(port)", "--user=\(user)"]
        if options.includeStructure && !options.includeData { args.append("--no-data") }
        if options.includeData && !options.includeStructure { args.append("--no-create-info") }
        if options.dropBeforeCreate { args.append("--add-drop-table") }
        if options.useInsertStatements { args.append("--complete-insert"); args.append("--skip-extended-insert") }

        // For MySQL a schema is a database; the schemas field is ignored (the database
        // is the scope). Tables restrict within it.
        let tables = options.tables.filter { !$0.isEmpty }
        if !tables.isEmpty {
            args.append(database)
            args.append(contentsOf: tables)
        } else if options.createDatabase {
            if options.dropBeforeCreate { args.append("--add-drop-database") }
            args.append("--databases")
            args.append(database)
        } else {
            args.append(database)
        }
        return args
    }
}
