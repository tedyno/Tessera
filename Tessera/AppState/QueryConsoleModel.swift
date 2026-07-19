import SwiftUI
import DBKit
import DBPersistence
import DBDriverPostgres
import DBDriverMySQL
import DBTunnel

/// A connection session: owns the driver (and SSH tunnel), the live schema, and a
/// set of query tabs that share the connection. Records executed queries to the
/// history store. Secrets come from the Keychain via the caller.
@MainActor
@Observable
final class QueryConsoleModel {
    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    private(set) var status: ConnectionStatus = .idle
    private(set) var connectionName: String?
    private(set) var currentProfileID: UUID?
    private(set) var engine: DatabaseKind?
    private(set) var serverVersion: String?
    private(set) var schema: DatabaseTree?

    var tabs: [QueryTab] = []
    var activeTabID: UUID?

    private(set) var history: [QueryHistoryEntry] = []

    private var driver: (any DatabaseDriver)?
    private var tunnel: SSHTunnel?
    private let historyStore: QueryHistoryStore

    private static let defaultSQL = """
        SELECT o.id, c.name, o.total, o.status, o.created_at
        FROM orders o
        JOIN customers c ON c.id = o.customer_id
        ORDER BY o.created_at DESC
        LIMIT 200;
        """

    init() {
        let url = (try? QueryHistoryStore.defaultURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tessera-history.json")
        self.historyStore = QueryHistoryStore(fileURL: url)
        self.history = historyStore.load()
        let tab = QueryTab(title: "Query 1", sql: Self.defaultSQL)
        tabs = [tab]
        activeTabID = tab.id
    }

    // MARK: Tabs

    var activeTab: QueryTab? { tabs.first { $0.id == activeTabID } }

    func addTab() {
        let tab = QueryTab(title: "Query \(tabs.count + 1)")
        tabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if tabs.isEmpty { addTab() }
        if activeTabID == id { activeTabID = tabs.last?.id }
    }

    // MARK: Connection

    var isConnecting: Bool { status == .connecting }

    var connectionError: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    func open(profile: ConnectionProfile, secrets: Secrets) async {
        tabs.forEach { $0.task?.cancel() }
        await driver?.close()
        await tunnel?.stop()
        tunnel = nil
        connectionName = profile.name
        currentProfileID = profile.id
        engine = profile.kind
        serverVersion = nil
        schema = nil
        status = .connecting

        do {
            let endpoint: NetworkEndpoint
            if let ssh = profile.ssh {
                let tunnel = SSHTunnel()
                endpoint = try await tunnel.start(
                    ssh: ssh, secrets: secrets,
                    remoteHost: profile.host, remotePort: profile.port)
                self.tunnel = tunnel
            } else {
                endpoint = NetworkEndpoint(host: profile.host, port: profile.port)
            }

            let driver: any DatabaseDriver = switch profile.kind {
            case .postgres: PostgresDriver()
            case .mysql: MySQLDriver()
            }
            self.driver = driver

            try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
            status = .ready
            serverVersion = try? await driver.serverVersion()
            schema = try? await driver.fetchSchema()
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    func refreshSchema() async {
        guard let driver else { return }
        schema = try? await driver.fetchSchema()
    }

    // MARK: Running queries

    /// ⌘↩ target: persist pending cell edits if any, otherwise run the SQL.
    func runOrCommit(_ tab: QueryTab) async {
        if tab.hasEdits { await commitEdits(tab) } else { await run(tab, sqlToRun: tab.sql) }
    }

    /// Which SQL to run given the caret position (statement under cursor, with
    /// subselect disambiguation).
    func resolveRunTarget(_ tab: QueryTab) -> SQLRunTarget {
        SQLStatements.resolve(sql: tab.sql, cursor: tab.cursorPosition)
    }

    func run(_ tab: QueryTab, sqlToRun: String? = nil) async {
        guard status == .ready, let driver, !tab.isRunning else { return }
        let sql = sqlToRun ?? tab.sql
        tab.isRunning = true
        tab.errorMessage = nil
        do {
            let result = try await driver.execute(sql)
            tab.result = result
            tab.edits = [:]
            tab.pendingDeletes = []
            tab.editSource = detectEditSource(sql: sql, columns: result.columns)
            let ms = result.elapsed.map(Self.milliseconds)
            tab.elapsedMS = ms
            recordHistory(sql: sql, rowCount: result.rows.count, elapsedMS: ms)
        } catch {
            tab.errorMessage = Self.message(for: error)
        }
        tab.isRunning = false
    }

    /// Writes pending cell edits as `UPDATE` statements (in a transaction), then
    /// re-runs the query to show the saved data.
    func commitEdits(_ tab: QueryTab) async {
        guard status == .ready, let driver, tab.editSource != nil, tab.hasEdits else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        do {
            // Per-statement (PostgresClient is pooled, so a wrapping BEGIN/COMMIT
            // wouldn't share one connection). A single-connection transaction is future work.
            for statement in pendingStatements(tab) {
                _ = try await driver.execute(statement)
            }
            tab.edits = [:]
            tab.pendingDeletes = []
            await run(tab, sqlToRun: tab.sql)
        } catch {
            tab.errorMessage = Self.message(for: error)
            tab.isRunning = false
        }
    }

    // MARK: Editable-source detection

    private func detectEditSource(sql: String, columns: [ColumnDescriptor]) -> EditSource? {
        let upper = sql.uppercased()
        // Any JOIN (even on a new line) means the result spans multiple tables — not editable.
        guard upper.contains("SELECT"),
              sql.range(of: #"(?i)\bjoin\b"#, options: .regularExpression) == nil else { return nil }
        guard let range = sql.range(of: #"(?i)\bfrom\s+([`"\w\.]+)"#, options: .regularExpression) else { return nil }
        let raw = sql[range].split(whereSeparator: { " \n\t".contains($0) }).last.map(String.init) ?? ""
        let cleaned = raw.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
        let parts = cleaned.split(separator: ".").map(String.init)
        guard let tableName = parts.last else { return nil }
        let schemaName = parts.count >= 2 ? parts[parts.count - 2] : nil

        // Find the table (optionally within the named schema).
        var found: (namespace: String, table: String, columns: [SchemaColumn])?
        for namespace in schema?.schemas ?? [] {
            if let schemaName, namespace.name.caseInsensitiveCompare(schemaName) != .orderedSame { continue }
            if let table = namespace.tables.first(where: { $0.name.caseInsensitiveCompare(tableName) == .orderedSame }) {
                found = (namespace.name, table.name, table.columns)
                break
            }
        }
        guard let found else { return nil }
        let primaryKeys = found.columns.filter(\.isPrimaryKey).map(\.name)
        let resultColumns = Set(columns.map(\.name))
        if !primaryKeys.isEmpty {
            // A PK exists but isn't in the result → can't target rows reliably.
            guard primaryKeys.allSatisfy(resultColumns.contains) else { return nil }
            return EditSource(schema: found.namespace, table: found.table, primaryKeys: primaryKeys)
        }
        // No primary key → fall back to matching all selected columns (may affect
        // duplicate rows).
        return EditSource(schema: found.namespace, table: found.table, primaryKeys: [])
    }

    /// The UPDATE/DELETE statements that ⌘↩ would run for the tab's pending changes.
    /// Rows with identical edits collapse into a single `… WHERE pk IN (…)`; deletes
    /// likewise. Without a primary key the WHERE matches all selected columns.
    func pendingStatements(_ tab: QueryTab) -> [String] {
        guard let source = tab.editSource, let result = tab.result else { return [] }
        let table = "\(quote(source.schema)).\(quote(source.table))"
        let keyColumns = source.primaryKeys.isEmpty ? result.columns.map(\.name) : source.primaryKeys
        var statements: [String] = []

        // DELETEs first.
        let deleteRows = tab.pendingDeletes.sorted()
        if !deleteRows.isEmpty {
            for clause in whereClauses(rows: deleteRows, keyColumns: keyColumns, result: result) {
                statements.append("DELETE FROM \(table) WHERE \(clause);")
            }
        }

        // UPDATEs grouped by identical change-set (skip rows being deleted).
        var groups: [String: (changes: [String: String], rows: [Int])] = [:]
        for (row, changes) in tab.edits where !tab.pendingDeletes.contains(row) {
            let key = changes.sorted { $0.key < $1.key }.map { "\($0.key)\u{1}\($0.value)" }.joined(separator: "\u{2}")
            groups[key, default: (changes, [])].rows.append(row)
        }
        for group in groups.values.sorted(by: { ($0.rows.min() ?? 0) < ($1.rows.min() ?? 0) }) {
            let setClause = group.changes.sorted { $0.key < $1.key }
                .map { "\(quote($0.key)) = \(Self.literal($0.value))" }.joined(separator: ", ")
            for clause in whereClauses(rows: group.rows.sorted(), keyColumns: keyColumns, result: result) {
                statements.append("UPDATE \(table) SET \(setClause) WHERE \(clause);")
            }
        }
        return statements
    }

    /// WHERE clauses for the given rows: one `col IN (…)` when the key is a single
    /// column with no NULLs, otherwise one AND-clause per row.
    private func whereClauses(rows: [Int], keyColumns: [String], result: QueryResult) -> [String] {
        if keyColumns.count == 1, let name = keyColumns.first,
           let index = result.columns.firstIndex(where: { $0.name == name }) {
            let values = rows.compactMap { row -> String? in
                guard row < result.rows.count, index < result.rows[row].count,
                      let text = result.rows[row][index].text else { return nil }
                return Self.literal(text)
            }
            if values.count == rows.count, !values.isEmpty {
                return ["\(quote(name)) IN (\(values.joined(separator: ", ")))"]
            }
        }
        return rows.map { rowWhere($0, keyColumns: keyColumns, result: result) }
    }

    private func rowWhere(_ row: Int, keyColumns: [String], result: QueryResult) -> String {
        keyColumns.compactMap { name -> String? in
            guard let index = result.columns.firstIndex(where: { $0.name == name }),
                  row < result.rows.count, index < result.rows[row].count else { return nil }
            let text = result.rows[row][index].text
            return text == nil ? "\(quote(name)) IS NULL" : "\(quote(name)) = \(Self.literal(text!))"
        }.joined(separator: " AND ")
    }

    private static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Puts `SELECT *` into the active tab and runs it (from a schema double-click).
    func selectAll(schema: String, table: String) async {
        let tab = activeTab ?? { addTab(); return activeTab! }()
        tab.sql = "SELECT * FROM \(quote(schema)).\(quote(table)) LIMIT 200;"
        await run(tab)
    }

    /// Quotes an identifier for the active engine so mixed-case / reserved names work.
    private func quote(_ identifier: String) -> String {
        switch engine {
        case .mysql:
            return "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        default:
            return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    func loadIntoActiveTab(_ sql: String) {
        if let tab = activeTab {
            tab.sql = sql
        } else {
            addTab()
            activeTab?.sql = sql
        }
    }

    private func recordHistory(sql: String, rowCount: Int, elapsedMS: Int?) {
        guard let connectionName else { return }
        let entry = QueryHistoryEntry(
            sql: sql, connectionName: connectionName, timestamp: Date(),
            rowCount: rowCount, elapsedMS: elapsedMS)
        history.insert(entry, at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
        // Persist off the main actor so a query never blocks the UI on disk I/O.
        let snapshot = history
        let store = historyStore
        Task.detached { store.save(snapshot) }
    }

    // MARK: Helpers

    private static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    private static func message(for error: Error) -> String {
        guard let dbError = error as? DatabaseError else { return String(describing: error) }
        switch dbError {
        case .notConnected: return "Not connected"
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .queryFailed(let m): return m
        case .cancelled: return "Cancelled"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}
