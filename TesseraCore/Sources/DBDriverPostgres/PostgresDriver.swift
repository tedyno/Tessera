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
    /// Backend PIDs of queries running right now. A set, because the actor is
    /// re-entrant: two tabs on one session can be mid-query at the same time, and
    /// Stop should cancel whatever this session is running.
    private var runningBackendPIDs: Set<Int> = []
    /// PID per pooled connection, so only the first query on a connection pays for
    /// the extra `pg_backend_pid()` round-trip.
    private var backendPIDCache: [PostgresConnection.ID: Int] = [:]
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

    public func execute(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        guard let client else { throw DatabaseError.notConnected }

        let clock = ContinuousClock()
        let start = clock.now
        let logger = Self.logger
        do {
            return try await client.withConnection { connection in
                // Remember which backend runs this query so it can be cancelled. The
                // PID is fixed per connection, so look it up once and reuse it.
                var pid = self.backendPIDCache[connection.id]
                if pid == nil,
                   let row = try await connection.query("SELECT pg_backend_pid()", logger: logger)
                    .collect().first, let value = try? row.decode(Int32.self) {
                    pid = Int(value)
                    self.backendPIDCache[connection.id] = pid
                }
                if let pid { self.runningBackendPIDs.insert(pid) }
                defer { if let pid { self.runningBackendPIDs.remove(pid) } }

                // A plain INSERT/UPDATE/DELETE returns no rows — report the affected
                // count from the command tag instead.
                if SQLText.isDML(sql) {
                    let result = try await connection.query(sql).get()
                    return QueryResult(columns: [], rows: [], rowsAffected: result.metadata.rows,
                                       elapsed: clock.now - start)
                }

                let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                var columns: [ColumnDescriptor] = []
                var resultRows: [[Cell]] = []
                var truncated = false

                for try await row in rows {
                    // Stop pulling once the cap is reached — the rest is never decoded.
                    if let maxRows, resultRows.count >= maxRows { truncated = true; break }
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
                return QueryResult(columns: columns, rows: resultRows,
                                   elapsed: clock.now - start, isTruncated: truncated)
            }
        } catch is CancellationError {
            throw DatabaseError.cancelled
        } catch {
            throw DatabaseError.queryFailed(Self.queryErrorMessage(error))
        }
    }

    /// Cancels whatever this session is running, from a second connection.
    public func cancelRunningQuery() async {
        guard let client, !runningBackendPIDs.isEmpty else { return }
        let pids = runningBackendPIDs
        let logger = Self.logger
        _ = try? await client.withConnection { connection in
            for pid in pids {
                _ = try await connection.query("SELECT pg_cancel_backend(\(pid))", logger: logger)
            }
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
        let result = try await execute("SHOW server_version", maxRows: nil)
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
            """, maxRows: nil)
        let columnsResult = try await execute("""
            SELECT table_schema, table_name, column_name, data_type, is_nullable,
                   column_default, is_identity
            FROM information_schema.columns
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            ORDER BY table_schema, table_name, ordinal_position
            """, maxRows: nil)
        let keyResult = try await execute("""
            SELECT tc.table_schema, tc.table_name, kcu.column_name, tc.constraint_type,
                   ccu.table_schema, ccu.table_name, ccu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
             AND tc.table_schema = kcu.table_schema
            LEFT JOIN information_schema.constraint_column_usage ccu
              ON tc.constraint_type = 'FOREIGN KEY'
             AND tc.constraint_name = ccu.constraint_name
             AND tc.table_schema = ccu.table_schema
            WHERE tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY')
            """, maxRows: nil)
        let indexResult = try await execute("""
            SELECT schemaname, tablename, indexname, indexdef
            FROM pg_indexes
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY schemaname, tablename, indexname
            """, maxRows: nil)

        var primaryKeys: Set<String> = []
        var foreignKeys: Set<String> = []
        var references: [String: ForeignKeyTarget] = [:]
        // A composite key yields one row per column; following a single column of one
        // would filter to the wrong rows, so only single-column keys get a target.
        var referenceColumnCount: [String: Int] = [:]
        for row in keyResult.rows where row.count >= 4 {
            let path = "\(row[0].text ?? "").\(row[1].text ?? "").\(row[2].text ?? "")"
            if row[3].text == "PRIMARY KEY" { primaryKeys.insert(path) }
            else if row[3].text == "FOREIGN KEY" {
                foreignKeys.insert(path)
                referenceColumnCount[path, default: 0] += 1
                if row.count >= 7, let schema = row[4].text, let table = row[5].text,
                   let column = row[6].text {
                    references[path] = ForeignKeyTarget(schema: schema, table: table, column: column)
                }
            }
        }
        for (path, count) in referenceColumnCount where count > 1 { references[path] = nil }

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
                    isAutoIncrement: hasSerialDefault || isIdentity,
                    references: references["\(schema).\(table).\(name)"]))
        }

        var indexesByTable: [TableKey: [SchemaIndex]] = [:]
        for row in indexResult.rows where row.count >= 4 {
            let key = TableKey(schema: row[0].text ?? "", table: row[1].text ?? "")
            indexesByTable[key, default: []].append(
                Self.parseIndex(name: row[2].text ?? "", definition: row[3].text ?? ""))
        }

        // Planner estimates, kept current by autovacuum — free to read, and the
        // sidebar only wants an order of magnitude anyway. -1 = never analyzed.
        let countsResult = try? await execute("""
            SELECT schemaname, relname, reltuples::bigint
            FROM pg_stat_user_tables
            JOIN pg_class ON pg_class.oid = relid
            """, maxRows: nil)
        var countsByTable: [TableKey: Int] = [:]
        for row in countsResult?.rows ?? [] where row.count >= 3 {
            if let count = row[2].text.flatMap(Int.init), count >= 0 {
                countsByTable[TableKey(schema: row[0].text ?? "", table: row[1].text ?? "")] = count
            }
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
                            indexes: indexesByTable[key] ?? [],
                            approximateRowCount: kind == .table ? countsByTable[key] : nil))
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
            // PostgresNIO delivers results in binary format, and it has no
            // Swift decoders for these — read the wire layout directly, or the
            // fallback below would render the raw bytes as UTF-8 garbage.
            case .time:
                if var buffer = cell.bytes,
                   let micros = buffer.readInteger(endianness: .big, as: Int64.self) {
                    return Self.timeOfDay(micros: micros)
                }
            case .timetz:
                if var buffer = cell.bytes,
                   let micros = buffer.readInteger(endianness: .big, as: Int64.self),
                   let zone = buffer.readInteger(endianness: .big, as: Int32.self) {
                    // The wire carries seconds WEST of UTC; display convention
                    // is the opposite sign.
                    return Self.timeOfDay(micros: micros) + Self.zoneOffset(seconds: -Int(zone))
                }
            case .interval:
                if var buffer = cell.bytes,
                   let micros = buffer.readInteger(endianness: .big, as: Int64.self),
                   let days = buffer.readInteger(endianness: .big, as: Int32.self),
                   let months = buffer.readInteger(endianness: .big, as: Int32.self) {
                    return Self.intervalText(micros: micros, days: Int(days), months: Int(months))
                }
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

    // MARK: Binary time formatting (internal for tests)

    /// Microseconds since midnight → `HH:mm:ss[.ffffff]`, fraction only when
    /// nonzero and with trailing zeros trimmed — matching psql's text output.
    static func timeOfDay(micros: Int64) -> String {
        let totalSeconds = micros / 1_000_000
        let fraction = Int(micros % 1_000_000)
        var text = String(format: "%02d:%02d:%02d",
                          totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
        if fraction != 0 {
            var digits = String(format: "%06d", fraction)
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return text
    }

    /// Display offset (already sign-flipped from the wire) → `±HH[:MM]`.
    static func zoneOffset(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude / 60) % 60
        return minutes == 0 ? String(format: "%@%02d", sign, hours)
                            : String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    /// Postgres-style interval text (`1 year 2 mons 3 days 04:05:06`), zero
    /// components omitted; a zero interval renders as `00:00:00`.
    static func intervalText(micros: Int64, days: Int, months: Int) -> String {
        var parts: [String] = []
        let years = months / 12
        let restMonths = months % 12
        if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
        if restMonths != 0 { parts.append("\(restMonths) mon\(abs(restMonths) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty {
            let sign = micros < 0 ? "-" : ""
            parts.append(sign + timeOfDay(micros: abs(micros)))
        }
        return parts.joined(separator: " ")
    }
}
