import Foundation
import DBKit
import PostgresNIO
import NIOSSL
import Logging

/// PostgreSQL implementation of `DatabaseDriver`, built on PostgresNIO's async
/// `PostgresClient` (with its built-in connection pool). One instance owns one
/// live connection pool; the UI creates one per session.
public actor PostgresDriver: DatabaseDriver {
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?
    private var databaseName: String?
    /// Backend PID of the connection currently running a query, for cancellation.
    private var runningBackendPID: Int?
    private static let logger = Logger(label: "io.github.tedyno.tessera.postgres")

    public init() {}

    public func connect(profile: ConnectionProfile, secrets: Secrets, endpoint: NetworkEndpoint) async throws {
        // Drop any prior connection so re-opening a driver is clean.
        await close()

        let config = PostgresClient.Configuration(
            host: endpoint.host,
            port: endpoint.port,
            username: profile.username,
            password: secrets.databasePassword,
            database: profile.database,
            tls: Self.makeTLS(profile.tlsMode)
        )

        let client = PostgresClient(configuration: config)
        // The pool only works while `run()` is executing; keep it alive in a task.
        let task = Task { await client.run() }
        self.client = client
        self.runTask = task
        self.databaseName = profile.database

        do {
            // Fail fast if the connection/auth is bad.
            _ = try await client.query("SELECT 1")
        } catch {
            await close()
            throw DatabaseError.connectionFailed(String(describing: error))
        }
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        guard let client else { throw DatabaseError.notConnected }

        let clock = ContinuousClock()
        let start = clock.now
        let logger = Self.logger
        do {
            return try await client.withConnection { connection in
                // Remember which backend runs this query so it can be cancelled.
                if let pidRow = try await connection.query("SELECT pg_backend_pid()", logger: logger)
                    .collect().first, let pid = try? pidRow.decode(Int32.self) {
                    self.runningBackendPID = Int(pid)
                }
                defer { self.runningBackendPID = nil }

                let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                var columns: [ColumnDescriptor] = []
                var resultRows: [[Cell]] = []

                for try await row in rows {
                    var cells: [Cell] = []
                    var index = 0
                    for cell in row {
                        if columns.count <= index {
                            columns.append(ColumnDescriptor(name: cell.columnName,
                                                            typeName: Self.typeName(cell.dataType)))
                        }
                        cells.append(Cell(Self.stringify(cell)))
                        index += 1
                    }
                    resultRows.append(cells)
                }
                return QueryResult(columns: columns, rows: resultRows, elapsed: clock.now - start)
            }
        } catch is CancellationError {
            throw DatabaseError.cancelled
        } catch {
            throw DatabaseError.queryFailed(Self.queryErrorMessage(error))
        }
    }

    /// Cancels the running query from a second connection via `pg_cancel_backend`.
    public func cancelRunningQuery() async {
        guard let client, let pid = runningBackendPID else { return }
        let logger = Self.logger
        _ = try? await client.withConnection { connection in
            _ = try await connection.query("SELECT pg_cancel_backend(\(pid))", logger: logger)
        }
    }

    /// Leases one pooled connection and runs everything in a single transaction, so
    /// a failed statement rolls the whole batch back.
    public func executeTransaction(_ statements: [String]) async throws {
        guard let client else { throw DatabaseError.notConnected }
        guard !statements.isEmpty else { return }
        do {
            let logger = Self.logger
            try await client.withConnection { connection in
                _ = try await connection.query("BEGIN", logger: logger)
                do {
                    for statement in statements {
                        _ = try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
                    }
                    _ = try await connection.query("COMMIT", logger: logger)
                } catch {
                    _ = try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        } catch is CancellationError {
            throw DatabaseError.cancelled
        } catch {
            throw DatabaseError.queryFailed(Self.queryErrorMessage(error))
        }
    }

    /// PostgresNIO's `PSQLError.description` is deliberately generic (to avoid
    /// leaking data in logs). Pull the real server message/detail/hint out of it.
    private static func queryErrorMessage(_ error: Error) -> String {
        guard let psql = error as? PSQLError, let info = psql.serverInfo else {
            return String(describing: error)
        }
        var line = ""
        if let severity = info[.localizedSeverity] { line += "\(severity): " }
        line += info[.message] ?? "query failed"
        if let detail = info[.detail] { line += "\nDETAIL: \(detail)" }
        if let hint = info[.hint] { line += "\nHINT: \(hint)" }
        if let state = info[.sqlState] { line += "\n(SQLSTATE \(state))" }
        return line
    }

    public func serverVersion() async throws -> String {
        let result = try await execute("SHOW server_version")
        let raw = result.rows.first?.first?.text ?? ""
        return raw.split(separator: " ").first.map(String.init) ?? raw
    }

    public func fetchSchema() async throws -> DatabaseTree {
        guard client != nil else { throw DatabaseError.notConnected }

        let tablesResult = try await execute("""
            SELECT table_schema, table_name, table_type
            FROM information_schema.tables
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            ORDER BY table_schema, table_name
            """)
        let columnsResult = try await execute("""
            SELECT table_schema, table_name, column_name, data_type, is_nullable,
                   column_default, is_identity
            FROM information_schema.columns
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            ORDER BY table_schema, table_name, ordinal_position
            """)
        let keyResult = try await execute("""
            SELECT tc.table_schema, tc.table_name, kcu.column_name, tc.constraint_type
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
             AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY')
            """)
        let indexResult = try await execute("""
            SELECT schemaname, tablename, indexname, indexdef
            FROM pg_indexes
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY schemaname, tablename, indexname
            """)

        var primaryKeys: Set<String> = []
        var foreignKeys: Set<String> = []
        for row in keyResult.rows where row.count >= 4 {
            let path = "\(row[0].text ?? "").\(row[1].text ?? "").\(row[2].text ?? "")"
            if row[3].text == "PRIMARY KEY" { primaryKeys.insert(path) }
            else if row[3].text == "FOREIGN KEY" { foreignKeys.insert(path) }
        }

        struct TableKey: Hashable { let schema: String; let table: String }
        var columnsByTable: [TableKey: [SchemaColumn]] = [:]
        for row in columnsResult.rows where row.count >= 7 {
            let schema = row[0].text ?? ""
            let table = row[1].text ?? ""
            let name = row[2].text ?? ""
            let key = TableKey(schema: schema, table: table)
            let hasSerialDefault = (row[5].text ?? "").hasPrefix("nextval(")
            let isIdentity = (row[6].text ?? "NO") == "YES"
            columnsByTable[key, default: []].append(
                SchemaColumn(
                    name: name,
                    dataType: row[3].text ?? "",
                    isPrimaryKey: primaryKeys.contains("\(schema).\(table).\(name)"),
                    isForeignKey: foreignKeys.contains("\(schema).\(table).\(name)"),
                    isNullable: (row[4].text ?? "YES") == "YES",
                    isAutoIncrement: hasSerialDefault || isIdentity))
        }

        var indexesByTable: [TableKey: [SchemaIndex]] = [:]
        for row in indexResult.rows where row.count >= 4 {
            let key = TableKey(schema: row[0].text ?? "", table: row[1].text ?? "")
            indexesByTable[key, default: []].append(
                Self.parseIndex(name: row[2].text ?? "", definition: row[3].text ?? ""))
        }

        var schemaOrder: [String] = []
        var tablesBySchema: [String: [SchemaTable]] = [:]
        for row in tablesResult.rows where row.count >= 3 {
            let schema = row[0].text ?? ""
            let table = row[1].text ?? ""
            let key = TableKey(schema: schema, table: table)
            let kind: SchemaTable.Kind = (row[2].text ?? "") == "VIEW" ? .view : .table
            if tablesBySchema[schema] == nil { schemaOrder.append(schema) }
            tablesBySchema[schema, default: []].append(
                SchemaTable(name: table, kind: kind,
                            columns: columnsByTable[key] ?? [],
                            indexes: indexesByTable[key] ?? []))
        }

        let namespaces = schemaOrder.map { SchemaNamespace(name: $0, tables: tablesBySchema[$0] ?? []) }
        return DatabaseTree(databaseName: databaseName ?? "database", schemas: namespaces)
    }

    public func close() async {
        runTask?.cancel()
        runTask = nil
        client = nil
    }

    // MARK: - Helpers

    /// Parses a Postgres `indexdef` (e.g. `CREATE UNIQUE INDEX x ON t USING btree (a, b)`).
    private static func parseIndex(name: String, definition: String) -> SchemaIndex {
        let isUnique = definition.uppercased().contains("UNIQUE INDEX")
        var columns: [String] = []
        if let open = definition.lastIndex(of: "("), let close = definition.lastIndex(of: ")"), open < close {
            let inner = definition[definition.index(after: open)..<close]
            columns = inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return SchemaIndex(name: name, columns: columns, isUnique: isUnique)
    }

    private static func makeTLS(_ mode: TLSMode) -> PostgresClient.Configuration.TLS {
        switch mode {
        case .disable:
            return .disable
        case .prefer:
            return .prefer(.makeClientConfiguration())
        case .require, .verifyCA, .verifyFull:
            return .require(.makeClientConfiguration())
        }
    }

    /// Renders a cell to display text. `nil` means SQL NULL. Decoding is driven by
    /// the column's actual Postgres type (values often arrive in binary format, so
    /// we must not blindly read bytes as text). Unknown types fall back to their
    /// text-format bytes.
    private static func stringify(_ cell: PostgresCell) -> String? {
        guard cell.bytes != nil else { return nil }
        do {
            switch cell.dataType {
            case .bool:
                return try cell.decode(Bool.self) ? "true" : "false"
            case .int2:
                return String(try cell.decode(Int16.self))
            case .int4, .oid:
                return String(try cell.decode(Int32.self))
            case .int8:
                return String(try cell.decode(Int64.self))
            case .float4:
                return String(try cell.decode(Float.self))
            case .float8:
                return String(try cell.decode(Double.self))
            case .numeric:
                return try cell.decode(Decimal.self).description
            case .uuid:
                // Postgres renders UUIDs lowercase; Swift's uuidString is uppercase.
                return try cell.decode(UUID.self).uuidString.lowercased()
            case .timestamp, .timestamptz, .date:
                return try cell.decode(Date.self).ISO8601Format()
            case .text, .varchar, .bpchar, .name, .char, .json, .jsonb:
                return try cell.decode(String.self)
            default:
                break
            }
        } catch {
            // Fall through to raw text handling below.
        }
        // Unknown types are requested in text format by the server; read directly.
        if let buffer = cell.bytes, let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
            return text
        }
        return "<binary>"
    }

    private static func typeName(_ dataType: PostgresDataType) -> String {
        String(describing: dataType)
    }
}
