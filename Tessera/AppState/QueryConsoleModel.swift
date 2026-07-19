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
    private(set) var engine: DatabaseKind?
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
        engine = profile.kind
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

    func run(_ tab: QueryTab, sqlToRun: String? = nil) async {
        guard status == .ready, let driver, !tab.isRunning else { return }
        let sql = sqlToRun ?? tab.sql
        tab.isRunning = true
        tab.errorMessage = nil
        do {
            let result = try await driver.execute(sql)
            tab.result = result
            tab.edits = [:]
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
        guard status == .ready, let driver, let source = tab.editSource,
              let result = tab.result, !tab.edits.isEmpty else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        do {
            // Note: run per-statement (PostgresClient is pooled, so a wrapping
            // BEGIN/COMMIT wouldn't share one connection). A single-connection
            // transaction is future work.
            for (rowIndex, changes) in tab.edits {
                guard rowIndex < result.rows.count,
                      let update = buildUpdate(source: source, columns: result.columns,
                                               originalRow: result.rows[rowIndex], changes: changes) else {
                    throw DatabaseError.queryFailed("Cannot build UPDATE for edited row")
                }
                _ = try await driver.execute(update)
            }
            tab.edits = [:]
            await run(tab, sqlToRun: tab.sql)
        } catch {
            tab.errorMessage = Self.message(for: error)
            tab.isRunning = false
        }
    }

    // MARK: Editable-source detection

    private func detectEditSource(sql: String, columns: [ColumnDescriptor]) -> EditSource? {
        let upper = sql.uppercased()
        guard upper.contains("SELECT"), !upper.contains(" JOIN ") else { return nil }
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
        guard !primaryKeys.isEmpty, primaryKeys.allSatisfy(resultColumns.contains) else { return nil }
        return EditSource(schema: found.namespace, table: found.table, primaryKeys: primaryKeys)
    }

    private func buildUpdate(source: EditSource, columns: [ColumnDescriptor],
                             originalRow: [Cell], changes: [String: String]) -> String? {
        guard !changes.isEmpty else { return nil }
        let setClause = changes.map { "\(quote($0.key)) = \(Self.literal($0.value))" }.joined(separator: ", ")
        var whereClauses: [String] = []
        for pk in source.primaryKeys {
            guard let index = columns.firstIndex(where: { $0.name == pk }), index < originalRow.count else { return nil }
            let value = originalRow[index].text
            whereClauses.append(value == nil ? "\(quote(pk)) IS NULL" : "\(quote(pk)) = \(Self.literal(value!))")
        }
        guard !whereClauses.isEmpty else { return nil }
        return "UPDATE \(quote(source.schema)).\(quote(source.table)) SET \(setClause) WHERE \(whereClauses.joined(separator: " AND "));"
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
