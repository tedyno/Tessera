import Foundation
import SQLite3
import DBKit

/// Holds the raw sqlite3 handle so `cancelRunningQuery` can call
/// `sqlite3_interrupt` from any thread while a query blocks the work queue.
/// The interrupt runs *inside* the lock, so `clear()` (called before
/// `sqlite3_close_v2`) can never race a freed handle.
private final class SQLiteHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    func set(_ new: OpaquePointer?) {
        lock.lock(); handle = new; lock.unlock()
    }

    func interrupt() {
        lock.lock()
        if let handle { sqlite3_interrupt(handle) }
        lock.unlock()
    }
}

/// SQLite driver on the system libsqlite3 (`import SQLite3`) — no external
/// dependency and no networking: `profile.database` is the file path, and the
/// endpoint/secrets are ignored. All database work is confined to one serial
/// queue (SQLite handles are not thread-safe for concurrent use); the async
/// protocol methods hop onto it via continuations, so the cooperative pool is
/// never blocked by a long query.
public final class SQLiteDriver: DatabaseDriver, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.tedyno.tessera.sqlite")
    /// Confined to `queue`.
    private var db: OpaquePointer?
    private let box = SQLiteHandleBox()

    public init() {}

    // MARK: Lifecycle

    public func connect(profile: ConnectionProfile, secrets: Secrets, endpoint: NetworkEndpoint) async throws {
        let path = profile.database
        try await onQueue {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
                if let handle { sqlite3_close_v2(handle) }
                throw DatabaseError.connectionFailed("\(path): \(message)")
            }
            sqlite3_busy_timeout(handle, 5000)
            // Match server engines, which enforce foreign keys by default.
            sqlite3_exec(handle, "PRAGMA foreign_keys = ON", nil, nil, nil)
            self.db = handle
            self.box.set(handle)
        }
    }

    public func close() async {
        try? await onQueue {
            self.box.set(nil)   // interrupts turn into no-ops before the handle dies
            if let db = self.db { sqlite3_close_v2(db) }
            self.db = nil
        }
    }

    public nonisolated func cancelRunningQuery() async {
        // Not on the queue — that's the point: the queue is busy running the
        // query this is meant to abort.
        box.interrupt()
    }

    public func serverVersion() async throws -> String {
        "SQLite \(String(cString: sqlite3_libversion()))"
    }

    // MARK: Queries

    public func execute(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        try await onQueue {
            guard let db = self.db else { throw DatabaseError.notConnected }
            return try Self.run(sql, on: db, maxRows: maxRows)
        }
    }

    public func stream(_ sql: String, batchSize: Int, into sink: RowSink) async throws {
        try await onQueue {
            guard let db = self.db else { throw DatabaseError.notConnected }
            try Self.stream(sql, on: db, batchSize: max(1, batchSize), into: sink)
        }
    }

    /// Streams the first result-producing statement's rows to `sink` in batches,
    /// executing any other statements for their side effects. Export runs a single
    /// SELECT, so "first columned statement" is unambiguous in practice.
    private static func stream(_ sql: String, on db: OpaquePointer,
                               batchSize: Int, into sink: RowSink) throws {
        var began = false
        try sql.withCString { base in
            var cursor: UnsafePointer<CChar>? = base
            while let current = cursor, current.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(db, current, -1, &statement, &tail) == SQLITE_OK else {
                    throw queryError(db)
                }
                cursor = tail
                guard let statement else { continue }
                defer { sqlite3_finalize(statement) }

                let columnCount = Int(sqlite3_column_count(statement))
                // Stream only the first result-producing statement; deliver its
                // columns once, up front — SQLite knows them before the first row,
                // so an empty result still yields a header.
                let stream = columnCount > 0 && !began
                if stream {
                    let columns = (0..<columnCount).map { index in
                        ColumnDescriptor(
                            name: String(cString: sqlite3_column_name(statement, Int32(index))),
                            typeName: sqlite3_column_decltype(statement, Int32(index))
                                .map { String(cString: $0).lowercased() } ?? "")
                    }
                    try sink.begin(columns: columns)
                    began = true
                }

                var batch: [[Cell]] = []
                stepping: while true {
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        guard stream else { continue }
                        batch.append((0..<columnCount).map { cell(statement, Int32($0)) })
                        if batch.count >= batchSize {
                            try sink.write(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    case SQLITE_DONE:
                        break stepping
                    case SQLITE_INTERRUPT:
                        throw DatabaseError.cancelled
                    default:
                        throw queryError(db)
                    }
                }
                if stream, !batch.isEmpty { try sink.write(batch) }
            }
        }
        if !began { try sink.begin(columns: []) }
        try sink.finish()
    }

    public func executeTransaction(_ statements: [String]) async throws {
        try await onQueue {
            guard let db = self.db else { throw DatabaseError.notConnected }
            try Self.exec("BEGIN", on: db)
            do {
                for statement in statements {
                    try Self.exec(statement, on: db)
                }
                try Self.exec("COMMIT", on: db)
            } catch {
                try? Self.exec("ROLLBACK", on: db)
                throw error
            }
        }
    }

    /// Runs a (possibly multi-statement) script; the last statement that
    /// produces columns supplies the grid, mirroring the other drivers.
    private static func run(_ sql: String, on db: OpaquePointer, maxRows: Int?) throws -> QueryResult {
        let clock = ContinuousClock()
        let start = clock.now
        var columns: [ColumnDescriptor] = []
        var rows: [[Cell]] = []
        var truncated = false
        var sawColumns = false
        // sqlite3_changes64 keeps the count of the last DML ever run, so a script
        // with no DML would report a stale number; the total-changes delta counts
        // exactly this script's writes (summed across its statements).
        let changesBefore = sqlite3_total_changes64(db)

        try sql.withCString { base in
            var cursor: UnsafePointer<CChar>? = base
            while let current = cursor, current.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(db, current, -1, &statement, &tail) == SQLITE_OK else {
                    throw queryError(db)
                }
                cursor = tail
                guard let statement else { continue }   // trailing whitespace/comment
                defer { sqlite3_finalize(statement) }

                let columnCount = Int(sqlite3_column_count(statement))
                var statementColumns: [ColumnDescriptor] = (0..<columnCount).map { index in
                    ColumnDescriptor(
                        name: String(cString: sqlite3_column_name(statement, Int32(index))),
                        typeName: sqlite3_column_decltype(statement, Int32(index))
                            .map { String(cString: $0).lowercased() } ?? "")
                }
                var statementRows: [[Cell]] = []
                var statementTruncated = false

                stepping: while true {
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        // Columns without a declared type get the dynamic type of
                        // the first value seen (expressions, PRAGMA output, …).
                        if statementRows.isEmpty {
                            for index in 0..<columnCount where statementColumns[index].typeName.isEmpty {
                                statementColumns[index].typeName =
                                    dynamicTypeName(statement, Int32(index))
                            }
                        }
                        if let maxRows, statementRows.count >= maxRows {
                            statementTruncated = true
                            continue   // keep stepping (side effects), stop collecting
                        }
                        statementRows.append((0..<columnCount).map { cell(statement, Int32($0)) })
                    case SQLITE_DONE:
                        break stepping
                    case SQLITE_INTERRUPT:
                        throw DatabaseError.cancelled
                    default:
                        throw queryError(db)
                    }
                }

                if columnCount > 0 {
                    sawColumns = true
                    columns = statementColumns
                    rows = statementRows
                    truncated = statementTruncated
                }
            }
        }

        if sawColumns {
            return QueryResult(columns: columns, rows: rows,
                               elapsed: clock.now - start, isTruncated: truncated,
                               returnsRows: true)
        }
        return QueryResult(columns: [], rows: [],
                           rowsAffected: Int(sqlite3_total_changes64(db) - changesBefore),
                           elapsed: clock.now - start)
    }

    private static func cell(_ statement: OpaquePointer, _ index: Int32) -> Cell {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_BLOB:
            return Cell("<blob \(sqlite3_column_bytes(statement, index)) bytes>")
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return Cell(String(cString: text))
        }
    }

    private static func dynamicTypeName(_ statement: OpaquePointer, _ index: Int32) -> String {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: "integer"
        case SQLITE_FLOAT: "real"
        case SQLITE_BLOB: "blob"
        case SQLITE_TEXT: "text"
        default: ""
        }
    }

    private static func exec(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw queryError(db)
        }
    }

    private static func queryError(_ db: OpaquePointer) -> DatabaseError {
        // A cancel can land while preparing the next statement of a script (or
        // inside exec), not just mid-step — every path must read as Cancelled.
        sqlite3_errcode(db) == SQLITE_INTERRUPT
            ? .cancelled
            : .queryFailed(String(cString: sqlite3_errmsg(db)))
    }

    // MARK: Introspection

    public func fetchSchema() async throws -> DatabaseTree {
        try await onQueue {
            guard let db = self.db else { throw DatabaseError.notConnected }
            return try Self.introspect(db)
        }
    }

    private static func introspect(_ db: OpaquePointer) throws -> DatabaseTree {
        // One namespace: SQLite has no schema layer (ATTACH is out of scope).
        let master = try run(
            "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view') "
            + "AND name NOT LIKE 'sqlite_%' ORDER BY name", on: db, maxRows: nil)

        // Row estimates exist only after ANALYZE (sqlite_stat1's stat column
        // leads with the entry count); absent stats just mean no badge.
        var rowCounts: [String: Int] = [:]
        if let stats = try? run("SELECT tbl, stat FROM sqlite_stat1", on: db, maxRows: nil) {
            for row in stats.rows where row.count >= 2 {
                guard let table = row[0].text,
                      let first = row[1].text?.split(separator: " ").first,
                      let count = Int(first) else { continue }
                // One row per index, each counting *that index's* entries — a
                // partial index covers only its WHERE subset, so the largest
                // entry count is the closest thing to the table's row count.
                rowCounts[table] = max(rowCounts[table] ?? 0, count)
            }
        }

        var tables: [SchemaTable] = []
        for row in master.rows {
            guard let name = row[0].text else { continue }
            let isView = row[1].text == "view"
            let createSQL = (row.count > 2 ? row[2].text : nil) ?? ""
            var schemaTable = try table(named: name, isView: isView, createSQL: createSQL, on: db)
            if !isView { schemaTable.approximateRowCount = rowCounts[name] }
            tables.append(schemaTable)
        }
        return DatabaseTree(databaseName: "main",
                            schemas: [SchemaNamespace(name: "main", tables: tables)])
    }

    private static func table(named name: String, isView: Bool, createSQL: String,
                              on db: OpaquePointer) throws -> SchemaTable {
        let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""

        // Single-column foreign keys → their target (composite keys are skipped,
        // matching the other drivers: following one column alone would mis-filter).
        // foreign_key_list: id, seq, table, from, to, on_update, on_delete, match
        var referencesByColumn: [String: ForeignKeyTarget] = [:]
        var columnsPerKey: [String: Int] = [:]
        let fks = try run("PRAGMA foreign_key_list(\(quoted))", on: db, maxRows: nil)
        for row in fks.rows where row.count >= 5 {
            columnsPerKey[row[0].text ?? "", default: 0] += 1
        }
        for row in fks.rows where row.count >= 5 {
            guard columnsPerKey[row[0].text ?? ""] == 1,
                  let from = row[3].text, let table = row[2].text else { continue }
            // "REFERENCES parent" without a column list leaves `to` NULL — the
            // constraint implicitly targets the parent's primary key.
            guard let to = row[4].text ?? (try? primaryKeyColumn(of: table, on: db)) ?? nil
            else { continue }
            referencesByColumn[from] = ForeignKeyTarget(schema: "main", table: table, column: to)
        }

        // table_info: cid, name, type, notnull, dflt_value, pk (1-based PK ordinal)
        let info = try run("PRAGMA table_info(\(quoted))", on: db, maxRows: nil)
        let primaryKeyCount = info.rows.filter { ($0.count > 5 ? $0[5].text : "0") != "0" }.count
        let upperSQL = createSQL.uppercased()
        let tableAutoIncrement = upperSQL.contains("AUTOINCREMENT")
        // A WITHOUT ROWID table has no rowid to alias — its INTEGER PK is a
        // plain column the user must supply.
        let hasRowID = !upperSQL.contains("WITHOUT ROWID")
        var columns: [SchemaColumn] = []
        for row in info.rows where row.count >= 6 {
            guard let columnName = row[1].text else { continue }
            let declaredType = row[2].text ?? ""
            let isPrimary = (row[5].text ?? "0") != "0"
            // A lone INTEGER PRIMARY KEY aliases the rowid: the database supplies
            // the value whether or not AUTOINCREMENT is spelled out.
            let isRowIDAlias = isPrimary && primaryKeyCount == 1 && hasRowID
                && declaredType.uppercased() == "INTEGER"
            columns.append(SchemaColumn(
                name: columnName,
                dataType: declaredType.lowercased(),
                isPrimaryKey: isPrimary,
                isForeignKey: referencesByColumn[columnName] != nil,
                isNullable: (row[3].text ?? "0") == "0",
                isAutoIncrement: isRowIDAlias || (isPrimary && tableAutoIncrement),
                references: referencesByColumn[columnName]))
        }

        // index_list: seq, name, unique, origin, partial — skip the PK's own
        // auto-index; index_info: seqno, cid, name
        var indexes: [SchemaIndex] = []
        if !isView {
            let list = try run("PRAGMA index_list(\(quoted))", on: db, maxRows: nil)
            for row in list.rows where row.count >= 4 {
                guard let indexName = row[1].text,
                      !indexName.hasPrefix("sqlite_autoindex_") else { continue }
                let quotedIndex = "\"" + indexName.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                let detail = try run("PRAGMA index_info(\(quotedIndex))", on: db, maxRows: nil)
                let indexColumns = detail.rows.compactMap { $0.count > 2 ? $0[2].text : nil }
                indexes.append(SchemaIndex(name: indexName, columns: indexColumns,
                                           isUnique: row[2].text == "1"))
            }
        }

        return SchemaTable(name: name, kind: isView ? .view : .table,
                           columns: columns, indexes: indexes)
    }

    /// The single primary-key column of a table, or nil when the key is
    /// composite or absent — used to resolve implicit FK targets.
    private static func primaryKeyColumn(of table: String, on db: OpaquePointer) throws -> String? {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let info = try run("PRAGMA table_info(\(quoted))", on: db, maxRows: nil)
        let pkColumns = info.rows.filter { ($0.count > 5 ? $0[5].text : "0") != "0" }
        return pkColumns.count == 1 ? pkColumns[0][1].text : nil
    }

    // MARK: Queue bridging

    /// Runs `work` on the serial database queue without blocking the caller's
    /// cooperative thread.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
