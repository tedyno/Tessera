import Foundation
import DBKit
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import Logging

/// MySQL implementation of `DatabaseDriver`, built on MySQLNIO. MySQLNIO has no
/// modern async pool, so this holds a single `MySQLConnection` and bridges its
/// `EventLoopFuture` API to async/await. One instance per session.
public actor MySQLDriver: DatabaseDriver {
    private var connection: MySQLConnection?
    private var databaseName: String?
    /// Kept so a second connection can be opened to `KILL QUERY` the running one.
    private var reconnectInfo: (profile: ConnectionProfile, secrets: Secrets, endpoint: NetworkEndpoint)?
    private var connectionID: Int?

    // Serializes access to the single connection: actor reentrancy would otherwise
    // let a second execute() interleave with a first at its `await`, and MySQLNIO's
    // connection cannot run concurrent queries.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    private func lock() async {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
    }

    private func unlock() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    public func connect(profile: ConnectionProfile, secrets: Secrets, endpoint: NetworkEndpoint) async throws {
        await close()
        do {
            let address = try SocketAddress.makeAddressResolvingHost(endpoint.host, port: endpoint.port)
            // Use the shared singleton group so no per-connection threads leak.
            let connection = try await MySQLConnection.connect(
                to: address,
                username: profile.username,
                database: profile.database,
                password: secrets.databasePassword ?? "",
                tlsConfiguration: Self.makeTLS(profile.tlsMode),
                logger: Self.driverLogger,
                on: MultiThreadedEventLoopGroup.singleton.next()
            ).get()
            self.connection = connection
            self.databaseName = profile.database
            self.reconnectInfo = (profile, secrets, endpoint)
            // Needed to target KILL QUERY at this session.
            if let rows = try? await connection.simpleQuery("SELECT CONNECTION_ID()").get(),
               let text = rows.first.flatMap({ Self.text($0.column("CONNECTION_ID()")) }) {
                self.connectionID = Int(text)
            }
        } catch {
            await close()
            throw DatabaseError.connectionFailed(String(describing: error))
        }
    }

    public func execute(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        await lock()
        defer { unlock() }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            // A plain INSERT/UPDATE/DELETE returns no rows — report the affected
            // count from the OK packet instead.
            if SQLText.isDML(sql) {
                nonisolated(unsafe) var affected: UInt64 = 0
                _ = try await connection.query(sql, onMetadata: { affected = $0.affectedRows }).get()
                return QueryResult(columns: [], rows: [], rowsAffected: Int(affected),
                                   elapsed: clock.now - start)
            }

            // simpleQuery uses the text protocol (COM_QUERY): every value arrives
            // as UTF-8 text, which is what we want for generic display.
            let rows = try await connection.simpleQuery(sql).get()
            var columns: [ColumnDescriptor] = []
            if let first = rows.first {
                columns = first.columnDefinitions.map {
                    ColumnDescriptor(name: $0.name, typeName: String(describing: $0.columnType))
                }
            }
            var resultRows: [[Cell]] = []
            var truncated = false
            for row in rows {
                // COM_QUERY buffers the whole result, so the cap trims what we keep
                // and decode rather than what the server sends.
                if let maxRows, resultRows.count >= maxRows { truncated = true; break }
                // Read values positionally: `row.column(name:)` does a linear scan of
                // the column list per cell (O(cols²) per row), and the text protocol
                // only needs the raw buffer anyway.
                var cells: [Cell] = []
                cells.reserveCapacity(row.values.count)
                for value in row.values {
                    cells.append(Cell(Self.text(buffer: value)))
                }
                resultRows.append(cells)
            }
            return QueryResult(columns: columns, rows: resultRows,
                               elapsed: clock.now - start, isTruncated: truncated)
        } catch is CancellationError {
            throw DatabaseError.cancelled
        } catch {
            throw DatabaseError.queryFailed(String(describing: error))
        }
    }

    public func stream(_ sql: String, batchSize: Int, into sink: RowSink) async throws {
        guard let connection else { throw DatabaseError.notConnected }
        let batchSize = max(1, batchSize)
        await lock()
        defer { unlock() }

        // DML has no result set; emit an empty header so the sink still yields a
        // valid (empty) file.
        if SQLText.isDML(sql) {
            do {
                _ = try await connection.simpleQuery(sql).get()
            } catch is CancellationError {
                throw DatabaseError.cancelled
            } catch {
                throw DatabaseError.queryFailed(String(describing: error))
            }
            try sink.begin(columns: [])
            try sink.finish()
            return
        }

        // Stream via the text-protocol `onRow` callback — the whole result never
        // buffers. `onRow` runs serially on the connection's event loop; the
        // captured state is only read back after `.get()` completes, so the future
        // provides the happens-before. Sink calls are synchronous; a thrown sink
        // error is stashed and rethrown (a callback can't throw or stop the query).
        nonisolated(unsafe) var began = false
        nonisolated(unsafe) var batch: [[Cell]] = []
        nonisolated(unsafe) var sinkError: Error?
        do {
            try await connection.simpleQuery(sql) { row in
                guard sinkError == nil else { return }
                do {
                    if !began {
                        let columns = row.columnDefinitions.map {
                            ColumnDescriptor(name: $0.name, typeName: String(describing: $0.columnType))
                        }
                        try sink.begin(columns: columns)
                        began = true
                    }
                    var cells: [Cell] = []
                    cells.reserveCapacity(row.values.count)
                    for value in row.values {
                        cells.append(Cell(Self.text(buffer: value)))
                    }
                    batch.append(cells)
                    if batch.count >= batchSize {
                        try sink.write(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                } catch {
                    sinkError = error
                }
            }.get()
        } catch is CancellationError {
            throw DatabaseError.cancelled
        } catch {
            if let sinkError { throw sinkError }
            throw DatabaseError.queryFailed(String(describing: error))
        }
        if let sinkError { throw sinkError }
        if !began { try sink.begin(columns: []) }
        if !batch.isEmpty { try sink.write(batch) }
        try sink.finish()
    }

    /// The single connection is already serialized by `lock()`, so a plain
    /// START TRANSACTION … COMMIT is atomic here.
    public func executeTransaction(_ statements: [String]) async throws {
        guard let connection else { throw DatabaseError.notConnected }
        guard !statements.isEmpty else { return }
        await lock()
        defer { unlock() }
        do {
            _ = try await connection.simpleQuery("START TRANSACTION").get()
            do {
                for statement in statements {
                    _ = try await connection.simpleQuery(statement).get()
                }
                _ = try await connection.simpleQuery("COMMIT").get()
            } catch {
                _ = try? await connection.simpleQuery("ROLLBACK").get()
                throw error
            }
        } catch is CancellationError {
            throw DatabaseError.cancelled
        } catch {
            throw DatabaseError.queryFailed(String(describing: error))
        }
    }

    /// Opens a short-lived second connection and issues `KILL QUERY` — the busy
    /// primary connection can't carry the request itself.
    public func cancelRunningQuery() async {
        guard let connectionID, let info = reconnectInfo else { return }
        guard let address = try? SocketAddress.makeAddressResolvingHost(info.endpoint.host,
                                                                       port: info.endpoint.port),
              let killer = try? await MySQLConnection.connect(
                to: address,
                username: info.profile.username,
                database: info.profile.database,
                password: info.secrets.databasePassword ?? "",
                tlsConfiguration: Self.makeTLS(info.profile.tlsMode),
                on: MultiThreadedEventLoopGroup.singleton.next()).get()
        else { return }
        _ = try? await killer.simpleQuery("KILL QUERY \(connectionID)").get()
        try? await killer.close().get()
    }

    public func serverVersion() async throws -> String {
        let result = try await execute("SELECT VERSION()", maxRows: nil)
        return result.rows.first?.first?.text ?? "unknown"
    }

    public func fetchSchema() async throws -> DatabaseTree {
        guard connection != nil else { throw DatabaseError.notConnected }
        let database = databaseName ?? ""

        // table_rows is the storage engine's estimate (exact only for MyISAM);
        // the sidebar badge just needs the magnitude.
        let tables = try await execute("""
            SELECT table_name, table_type, table_rows FROM information_schema.tables
            WHERE table_schema = DATABASE() ORDER BY table_name
            """, maxRows: nil)
        let columns = try await execute("""
            SELECT table_name, column_name, data_type, is_nullable, column_key, extra
            FROM information_schema.columns
            WHERE table_schema = DATABASE()
            ORDER BY table_name, ordinal_position
            """, maxRows: nil)
        let foreignKeysResult = try await execute("""
            SELECT table_name, column_name, referenced_table_schema,
                   referenced_table_name, referenced_column_name, constraint_name
            FROM information_schema.key_column_usage
            WHERE table_schema = DATABASE() AND referenced_table_name IS NOT NULL
            """, maxRows: nil)
        let statistics = try await execute("""
            SELECT table_name, index_name, non_unique, column_name, seq_in_index
            FROM information_schema.statistics
            WHERE table_schema = DATABASE()
            ORDER BY table_name, index_name, seq_in_index
            """, maxRows: nil)

        var foreignKeys: Set<String> = []
        var references: [String: ForeignKeyTarget] = [:]
        // One row per column of a composite key; a single column of one filters to the
        // wrong rows, so only single-column keys keep a target.
        var constraintColumns: [String: Int] = [:]
        var pathForConstraint: [String: [String]] = [:]
        for row in foreignKeysResult.rows where row.count >= 2 {
            let path = "\(row[0].text ?? "").\(row[1].text ?? "")"
            foreignKeys.insert(path)
            guard row.count >= 6, let table = row[3].text, let column = row[4].text else { continue }
            let constraint = "\(row[0].text ?? "").\(row[5].text ?? "")"
            constraintColumns[constraint, default: 0] += 1
            pathForConstraint[constraint, default: []].append(path)
            references[path] = ForeignKeyTarget(schema: row[2].text ?? database,
                                                table: table, column: column)
        }
        for (constraint, count) in constraintColumns where count > 1 {
            for path in pathForConstraint[constraint] ?? [] { references[path] = nil }
        }

        var columnsByTable: [String: [SchemaColumn]] = [:]
        for row in columns.rows where row.count >= 6 {
            let table = row[0].text ?? ""
            let name = row[1].text ?? ""
            columnsByTable[table, default: []].append(
                SchemaColumn(
                    name: name,
                    dataType: row[2].text ?? "",
                    isPrimaryKey: (row[4].text ?? "") == "PRI",
                    isForeignKey: foreignKeys.contains("\(table).\(name)"),
                    isNullable: (row[3].text ?? "YES") == "YES",
                    isAutoIncrement: (row[5].text ?? "").lowercased().contains("auto_increment"),
                    references: references["\(table).\(name)"]))
        }

        // Aggregate index columns (ordered by seq_in_index) per (table, index).
        struct IndexKey: Hashable { let table: String; let index: String }
        var indexColumns: [IndexKey: [String]] = [:]
        var indexUnique: [IndexKey: Bool] = [:]
        var indexOrder: [String: [String]] = [:]
        for row in statistics.rows where row.count >= 5 {
            let table = row[0].text ?? ""
            let indexName = row[1].text ?? ""
            let key = IndexKey(table: table, index: indexName)
            if indexColumns[key] == nil {
                indexOrder[table, default: []].append(indexName)
                indexUnique[key] = (row[2].text ?? "1") == "0"
            }
            indexColumns[key, default: []].append(row[3].text ?? "")
        }

        var indexesByTable: [String: [SchemaIndex]] = [:]
        for (table, names) in indexOrder {
            indexesByTable[table] = names.map { name in
                let key = IndexKey(table: table, index: name)
                return SchemaIndex(name: name, columns: indexColumns[key] ?? [], isUnique: indexUnique[key] ?? false)
            }
        }

        var schemaTables: [SchemaTable] = []
        for row in tables.rows where row.count >= 2 {
            let name = row[0].text ?? ""
            let kind: SchemaTable.Kind = (row[1].text ?? "").uppercased().contains("VIEW") ? .view : .table
            let rowCount = row.count >= 3 ? row[2].text.flatMap(Int.init) : nil
            schemaTables.append(SchemaTable(name: name, kind: kind,
                                            columns: columnsByTable[name] ?? [],
                                            indexes: indexesByTable[name] ?? [],
                                            approximateRowCount: kind == .table ? rowCount : nil))
        }

        return DatabaseTree(databaseName: database, schemas: [SchemaNamespace(name: database, tables: schemaTables)])
    }

    public func close() async {
        if let connection {
            try? await connection.close().get()
        }
        connection = nil
    }

    // MARK: - Helpers

    /// MySQLNIO traces every step of the handshake, which is the only way to see
    /// where a connection stalls. Off unless `TESSERA_DB_TRACE` is set, so normal
    /// runs stay quiet.
    private static let driverLogger: Logger = {
        var logger = Logger(label: "tessera.mysql")
        logger.logLevel = ProcessInfo.processInfo.environment["TESSERA_DB_TRACE"] == nil
            ? .critical : .trace
        return logger
    }()

    private static func makeTLS(_ mode: TLSMode) -> TLSConfiguration? {
        switch mode {
        case .disable:
            return nil
        case .prefer, .require:
            var config = TLSConfiguration.makeClientConfiguration()
            config.certificateVerification = .none
            return config
        case .verifyCA, .verifyFull:
            return .makeClientConfiguration()
        }
    }

    private static func text(_ data: MySQLData?) -> String? {
        // COM_QUERY uses the text protocol, so every non-null value is UTF-8 text
        // in the buffer regardless of column type (int, decimal, datetime, …).
        text(buffer: data?.buffer)
    }

    /// Decodes a raw column buffer straight to text, skipping the `MySQLData`
    /// wrapper — the row loop reads values positionally.
    private static func text(buffer: ByteBuffer?) -> String? {
        guard var buffer else { return nil }
        return buffer.readString(length: buffer.readableBytes)
    }
}
