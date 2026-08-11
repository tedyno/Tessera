import Foundation

/// How to feed a dump back into a database.
public enum RestoreInput: Sendable, Equatable {
    /// Plain `.sql` text, fed to psql / mysql.
    case plainSQL
    /// Gzipped `.sql.gz`; decompressed on the fly and piped in.
    case gzippedSQL
    /// pg_dump's custom format (`.dump`), restored with pg_restore.
    case pgCustom

    /// Guesses the input kind from a file name.
    public static func detect(fileName: String) -> RestoreInput {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".dump") || lower.hasSuffix(".backup") { return .pgCustom }
        if lower.hasSuffix(".gz") { return .gzippedSQL }
        return .plainSQL
    }

    /// True when the tool reads the dump from stdin rather than opening it itself.
    public var readsStandardInput: Bool { self == .gzippedSQL }
}

public struct RestoreOptions: Sendable, Equatable {
    /// Abort on the first failing statement (psql `ON_ERROR_STOP`).
    public var stopOnError: Bool
    /// Wrap the whole import in one transaction, so a failure leaves nothing behind.
    public var singleTransaction: Bool
    /// pg_restore only: drop objects before recreating them.
    public var dropBeforeCreate: Bool

    public init(stopOnError: Bool = true, singleTransaction: Bool = true,
                dropBeforeCreate: Bool = false) {
        self.stopOnError = stopOnError
        self.singleTransaction = singleTransaction
        self.dropBeforeCreate = dropBeforeCreate
    }
}

/// Builds command lines for restoring a dump (`psql`, `pg_restore`, `mysql`).
/// Pure and unit-tested; the app layer spawns the process.
public enum RestoreTool {
    public static func binaryName(for engine: DatabaseKind, input: RestoreInput) -> String {
        switch engine {
        case .postgres: input == .pgCustom ? "pg_restore" : "psql"
        case .mysql: "mysql"
        case .mariadb: "mariadb"
        case .sqlite: "sqlite3"   // unreachable via the UI; kept total for safety
        case .redis: "redis-cli"   // unreachable: restore is SQL-only
        }
    }

    /// Alternative binaries worth trying when the preferred one is missing (the
    /// `mysql` client restores MariaDB dumps and vice versa).
    public static func fallbackBinaryNames(for engine: DatabaseKind) -> [String] {
        engine == .mariadb ? ["mysql"] : []
    }

    public static func installHint(for engine: DatabaseKind) -> String {
        switch engine {
        case .postgres:
            """
            Install psql / pg_restore — in Terminal, run:
              brew install libpq && brew link --force libpq
            Then Browse to it (or paste the path):
              /opt/homebrew/opt/libpq/bin/psql   (Apple Silicon)
              /usr/local/opt/libpq/bin/psql      (Intel)
            """
        case .mysql:
            """
            Install the mysql client — in Terminal, run:
              brew install mysql-client && brew link --force mysql-client
            Then Browse to it (or paste the path):
              /opt/homebrew/opt/mysql-client/bin/mysql   (Apple Silicon)
              /usr/local/opt/mysql-client/bin/mysql      (Intel)
            """
        case .mariadb:
            """
            Install the mariadb client — in Terminal, run:
              brew install mariadb
            Then Browse to it (or paste the path):
              /opt/homebrew/bin/mariadb   (Apple Silicon)
              /usr/local/bin/mariadb      (Intel)
            The mysql client from mysql-client works as well.
            """
        case .sqlite:
            "SQLite databases are single files — no restore tool is needed."
        case .redis:
            "Redis connections have no SQL restore tool."
        }
    }

    /// Password goes through the environment, never argv.
    public static func environment(engine: DatabaseKind, password: String?) -> [String: String] {
        DumpTool.environment(kind: engine, password: password)
    }

    /// Arguments for the restore. When `input.readsStandardInput` the dump arrives on
    /// stdin, so no file argument is emitted.
    public static func arguments(engine: DatabaseKind, host: String, port: Int, user: String,
                                 database: String, input: RestoreInput, filePath: String,
                                 options: RestoreOptions) -> [String] {
        switch engine {
        case .postgres:
            input == .pgCustom
                ? pgRestoreArguments(host: host, port: port, user: user, database: database,
                                     filePath: filePath, options: options)
                : psqlArguments(host: host, port: port, user: user, database: database,
                                input: input, filePath: filePath, options: options)
        case .mysql, .mariadb:
            ["--host=\(host)", "--port=\(port)", "--user=\(user)", database]
        case .sqlite, .redis:
            []   // unreachable: import is disabled for these engines
        }
    }

    private static func psqlArguments(host: String, port: Int, user: String, database: String,
                                      input: RestoreInput, filePath: String,
                                      options: RestoreOptions) -> [String] {
        var args = ["--host=\(host)", "--port=\(port)", "--username=\(user)",
                    "--dbname=\(database)", "--no-password"]
        if options.stopOnError { args.append(contentsOf: ["-v", "ON_ERROR_STOP=1"]) }
        if options.singleTransaction { args.append("--single-transaction") }
        // Gzipped input is piped in on stdin; plain files psql opens itself.
        if !input.readsStandardInput { args.append(contentsOf: ["-f", filePath]) }
        return args
    }

    private static func pgRestoreArguments(host: String, port: Int, user: String, database: String,
                                           filePath: String, options: RestoreOptions) -> [String] {
        var args = ["--host=\(host)", "--port=\(port)", "--username=\(user)",
                    "--dbname=\(database)", "--no-password", "--no-owner"]
        if options.dropBeforeCreate { args.append(contentsOf: ["--clean", "--if-exists"]) }
        if options.singleTransaction { args.append("--single-transaction") }
        args.append(filePath)
        return args
    }
}
