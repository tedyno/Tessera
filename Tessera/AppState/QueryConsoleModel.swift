import SwiftUI
import DBKit
import DBPersistence

/// Manages the open connection sessions and the query tabs across them. Each tab
/// belongs to a `ConnectionSession`, so several databases (e.g. staging and
/// production) stay live at once; the active tab decides which session drives the
/// schema sidebar and status bar. Records executed queries to the history store.
@MainActor
@Observable
final class QueryConsoleModel {
    /// Live connections, one per opened profile (kept even when disconnected).
    var sessions: [ConnectionSession] = []

    var tabs: [QueryTab] = []
    var activeTabID: UUID?

    private(set) var history: [QueryHistoryEntry] = []
    private let historyStore: QueryHistoryStore

    /// User-bookmarked SQL snippets, newest first.
    private(set) var savedQueries: [SavedQuery] = []
    private let savedQueryStore: SavedQueryStore

    /// Injected by `AppModel`: reconnects a dropped session (it needs Keychain
    /// secrets, which live outside the console). Lets a run auto-reconnect first.
    var reconnect: (ConnectionSession) async -> Void = { _ in }

    /// Ensures the session is live, reconnecting on demand, before a query runs.
    private func ensureReady(_ session: ConnectionSession) async -> Bool {
        if session.isReady { return true }
        if !session.isConnecting { await reconnect(session) }
        return session.isReady
    }

    init() {
        let url = (try? QueryHistoryStore.defaultURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tessera-history.json")
        self.historyStore = QueryHistoryStore(fileURL: url)
        self.history = historyStore.load()

        let savedURL = (try? SavedQueryStore.defaultURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tessera-saved-queries.json")
        self.savedQueryStore = SavedQueryStore(fileURL: savedURL)
        self.savedQueries = savedQueryStore.load()
    }

    // MARK: Active tab / session

    var activeTab: QueryTab? { tabs.first { $0.id == activeTabID } }
    var activeSession: ConnectionSession? { activeTab?.session }

    /// Connection state of the active tab's session, surfaced for the status bar.
    var status: ConnectionSession.Status { activeSession?.status ?? .idle }
    var schema: DatabaseTree? { activeSession?.schema }
    var engine: DatabaseKind? { activeSession?.engine }
    var serverVersion: String? { activeSession?.serverVersion }
    var connectionName: String? { activeSession?.name }
    var currentProfileID: UUID? { activeSession?.id }
    var isConnecting: Bool { activeSession?.isConnecting ?? false }
    var connectionError: String? { activeSession?.errorMessage }

    // MARK: Sessions

    func session(for profileID: UUID) -> ConnectionSession? { sessions.first { $0.id == profileID } }

    /// The session for a profile, created (idle) if it doesn't exist yet.
    func ensureSession(profile: ConnectionProfile) -> ConnectionSession {
        if let existing = session(for: profile.id) { return existing }
        let session = ConnectionSession(profile: profile)
        sessions.append(session)
        return session
    }

    /// Activates the session's most recent tab, creating a console tab if it has none.
    func activateTab(for session: ConnectionSession) {
        if let tab = tabs.last(where: { $0.session === session }) {
            activeTabID = tab.id
        } else {
            let tab = QueryTab(title: "Query 1")
            tab.session = session
            tabs.append(tab)
            activeTabID = tab.id
        }
    }

    // MARK: Tabs

    func addTab() {
        let tab = QueryTab(title: "Query \(tabs.count + 1)")
        tab.session = activeSession ?? sessions.last
        tabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.task?.cancel()
        tabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = tabs.last?.id }
    }

    /// Closes every tab whose id is in `ids`, cancelling anything they were running.
    private func closeTabs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for tab in tabs where ids.contains(tab.id) { tab.task?.cancel() }
        tabs.removeAll { ids.contains($0.id) }
        if let active = activeTabID, ids.contains(active) { activeTabID = tabs.last?.id }
    }

    func closeOtherTabs(_ id: UUID) {
        closeTabs(Set(tabs.map(\.id).filter { $0 != id }))
    }

    func closeAllTabs() {
        closeTabs(Set(tabs.map(\.id)))
    }

    func closeTabsToLeft(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTabs(Set(tabs[..<index].map(\.id)))
    }

    func closeTabsToRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTabs(Set(tabs[(index + 1)...].map(\.id)))
    }

    /// Whether there is anything to close on that side / elsewhere, so the tab menu
    /// can grey out items that would do nothing.
    func hasTabs(toLeftOf id: UUID) -> Bool {
        (tabs.firstIndex { $0.id == id }).map { $0 > 0 } ?? false
    }

    func hasTabs(toRightOf id: UUID) -> Bool {
        (tabs.firstIndex { $0.id == id }).map { $0 < tabs.count - 1 } ?? false
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

    func run(_ tab: QueryTab, sqlToRun: String? = nil, preserveSort: Bool = false) async {
        guard let session = tab.session, !tab.isRunning else { return }
        let sql = sqlToRun ?? tab.sql
        if !preserveSort { tab.sortColumn = nil }
        tab.isRunning = true
        tab.errorMessage = nil
        // Reconnect a dropped connection first, then run.
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? "Not connected"
            tab.isRunning = false
            return
        }
        do {
            let cap = ExportSettings.maxRows
            let result = try await driver.execute(sql, maxRows: cap > 0 ? cap : nil)
            tab.result = result
            tab.resultVersion &+= 1
            tab.scriptSummary = nil
            tab.edits = [:]
            tab.pendingDeletes = []
            tab.pendingInserts = []
            tab.editSource = detectEditSource(sql: sql, columns: result.columns, schema: session.schema)
            let ms = result.elapsed.map(Self.milliseconds)
            tab.elapsedMS = ms
            recordHistory(sql: sql, session: session, rowCount: result.rows.count, elapsedMS: ms,
                          schema: tab.kind == .data ? tab.dataSchema : nil,
                          table: tab.kind == .data ? tab.dataTable : nil)
        } catch {
            tab.errorMessage = ConnectionSession.message(for: error)
        }
        tab.isRunning = false
    }

    /// Runs a multi-statement script (e.g. a loaded `.sql` file) against the tab's
    /// session, statement by statement, stopping on the first error. Shows the last
    /// result; on failure reports which statement failed.
    func runScript(_ tab: QueryTab) async {
        guard let session = tab.session, !tab.isRunning else { return }
        let statements = SQLScript.statements(in: tab.sql)
        guard !statements.isEmpty else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? "Not connected"
            tab.isRunning = false
            return
        }
        var lastResult: QueryResult?
        var executed = 0
        do {
            let cap = ExportSettings.maxRows
            for statement in statements {
                lastResult = try await driver.execute(statement, maxRows: cap > 0 ? cap : nil)
                executed += 1
                recordHistory(sql: statement, session: session,
                              rowCount: lastResult?.rows.count ?? 0, elapsedMS: nil)
            }
            tab.result = lastResult ?? QueryResult()
            tab.resultVersion &+= 1
            tab.edits = [:]; tab.pendingDeletes = []; tab.pendingInserts = []
            tab.editSource = nil   // a script isn't a single editable table view
            tab.scriptSummary = "Executed \(executed) statement\(executed == 1 ? "" : "s")"
        } catch {
            tab.scriptSummary = nil
            tab.errorMessage = "Statement \(executed + 1) of \(statements.count) failed:\n"
                + ConnectionSession.message(for: error)
        }
        tab.isRunning = false
    }

    /// Writes pending edits/deletes/inserts, then re-runs the query to show saved data.
    func commitEdits(_ tab: QueryTab) async {
        guard let session = tab.session, tab.editSource != nil, tab.hasEdits else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? "Not connected"
            tab.isRunning = false
            return
        }
        do {
            // One transaction on a single connection: either every pending change
            // lands or none of them do.
            try await driver.executeTransaction(pendingStatements(tab))
            tab.edits = [:]
            tab.pendingDeletes = []
            tab.pendingInserts = []
            tab.isRunning = false   // clear before re-running, else run()'s guard bails
            await run(tab, sqlToRun: tab.sql, preserveSort: true)
        } catch {
            tab.errorMessage = ConnectionSession.message(for: error)
            tab.isRunning = false
        }
    }

    // MARK: Editable-source detection

    private func detectEditSource(sql: String, columns: [ColumnDescriptor], schema: DatabaseTree?) -> EditSource? {
        let upper = sql.uppercased()
        // Only a plain full-table view is editable. A JOIN, aggregation, DISTINCT,
        // or UNION makes a custom result whose rows don't map 1:1 to table rows.
        guard upper.contains("SELECT"),
              sql.range(of: #"(?i)\b(join|group\s+by|having|distinct|union)\b"#,
                        options: .regularExpression) == nil else { return nil }
        // The projection must be a star ("SELECT *" or "SELECT alias.*") — a custom
        // column list or expressions (e.g. count(*), a+b) can't be written back.
        guard let selectRange = sql.range(of: #"(?i)\bselect\b"#, options: .regularExpression),
              let fromKeyword = sql.range(of: #"(?i)\bfrom\b"#, options: .regularExpression),
              selectRange.upperBound <= fromKeyword.lowerBound else { return nil }
        let projection = sql[selectRange.upperBound..<fromKeyword.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard projection == "*" || projection.range(of: #"^[`"\w]+\.\*$"#, options: .regularExpression) != nil
        else { return nil }
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
        let autoIncrement = found.columns.filter(\.isAutoIncrement).map(\.name)
        let resultColumns = Set(columns.map(\.name))
        if !primaryKeys.isEmpty {
            // A PK exists but isn't in the result → can't target rows reliably.
            guard primaryKeys.allSatisfy(resultColumns.contains) else { return nil }
            return EditSource(schema: found.namespace, table: found.table,
                              primaryKeys: primaryKeys, autoIncrementColumns: autoIncrement)
        }
        // No primary key → fall back to matching all selected columns (may affect
        // duplicate rows).
        return EditSource(schema: found.namespace, table: found.table,
                          primaryKeys: [], autoIncrementColumns: autoIncrement)
    }

    /// Appends a blank row queued for insertion (from the grid's "Add Row").
    func addInsertRow(_ tab: QueryTab) {
        guard tab.isEditable else { return }
        tab.pendingInserts.append(PendingInsert())
    }

    /// Drops every pending edit, delete, and insert without touching the database.
    func discardPending(_ tab: QueryTab) {
        tab.edits = [:]
        tab.pendingDeletes = []
        tab.pendingInserts = []
    }

    /// Header-click sorting on a full-table view: cycles ascending → descending →
    /// off for the clicked column, rewriting the query's `ORDER BY` and re-running.
    func sortByColumn(_ tab: QueryTab, column: String) async {
        guard tab.isEditable, !tab.hasEdits, let session = tab.session else { return }
        if tab.sortColumn == column {
            if tab.sortAscending { tab.sortAscending = false }
            else { tab.sortColumn = nil }
        } else {
            tab.sortColumn = column
            tab.sortAscending = true
        }
        if tab.kind == .data {
            await reloadData(tab)   // rebuilds the generated query with the new ORDER BY
            return
        }
        let newSQL = rewriteOrderBy(tab.sql, column: tab.sortColumn, ascending: tab.sortAscending, session: session)
        tab.sql = newSQL
        await run(tab, sqlToRun: newSQL, preserveSort: true)
    }

    /// Replaces the top-level `ORDER BY` of a full-table query (inserted before any
    /// `LIMIT`/`OFFSET`/`;`). A nil column removes ordering entirely. Matching ignores
    /// text inside string literals, so a WHERE value like `'a limit b'` is safe.
    private func rewriteOrderBy(_ sql: String, column: String?, ascending: Bool,
                                session: ConnectionSession) -> String {
        var body = sql
        if let existing = Self.topLevelRange(
            in: body, pattern: #"(?is)\s+ORDER\s+BY\s+.*?(?=(\s+LIMIT\b|\s+OFFSET\b|\s*;\s*$|$))"#) {
            body.removeSubrange(existing)
        }
        guard let column else { return body }
        let clause = " ORDER BY \(session.quote(column)) \(ascending ? "ASC" : "DESC")"
        if let tail = Self.topLevelRange(in: body, pattern: #"(?is)\s*(LIMIT\b|OFFSET\b|;\s*$)"#) {
            body.insert(contentsOf: clause, at: tail.lowerBound)
        } else {
            body += clause
        }
        return body
    }

    /// A regex match on `s`, but searched against a copy with string-literal contents
    /// blanked out so SQL keywords inside `'…'` don't match. Length is preserved, so
    /// the returned range indexes into the original `s`.
    private static func topLevelRange(in s: String, pattern: String) -> Range<String.Index>? {
        let masked = maskStringLiterals(s)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(masked.startIndex..., in: masked)
        guard let match = regex.firstMatch(in: masked, range: range), match.range.length > 0 else { return nil }
        return Range(match.range, in: s)
    }

    /// Replaces each character inside a single-quoted literal with `x`, preserving the
    /// quotes and the string's length (so ranges map back to the original 1:1).
    private static func maskStringLiterals(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inQuote = false
        for character in s {
            if character == "'" {
                inQuote.toggle()
                out.append(character)
            } else {
                out.append(inQuote ? "x" : character)
            }
        }
        return out
    }

    /// The UPDATE/DELETE/INSERT statements ⌘↩ would run for the tab's pending changes.
    /// Rows with identical edits collapse into a single `… WHERE pk IN (…)`; deletes
    /// likewise. Without a primary key the WHERE matches all selected columns.
    func pendingStatements(_ tab: QueryTab) -> [String] {
        guard let session = tab.session, let source = tab.editSource, let result = tab.result else { return [] }
        let table = "\(session.quote(source.schema)).\(session.quote(source.table))"
        let keyColumns = source.primaryKeys.isEmpty ? result.columns.map(\.name) : source.primaryKeys
        var statements: [String] = []

        // DELETEs first.
        let deleteRows = tab.pendingDeletes.sorted()
        if !deleteRows.isEmpty {
            for clause in whereClauses(rows: deleteRows, keyColumns: keyColumns, result: result, session: session) {
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
                .map { "\(session.quote($0.key)) = \(literal($0.value, columnName: $0.key, result: result))" }
                .joined(separator: ", ")
            for clause in whereClauses(rows: group.rows.sorted(), keyColumns: keyColumns, result: result, session: session) {
                statements.append("UPDATE \(table) SET \(setClause) WHERE \(clause);")
            }
        }

        // INSERTs — auto-increment columns are always omitted (the DB fills them),
        // as are columns the user never set (their defaults apply).
        let autoInc = Set(source.autoIncrementColumns)
        for insert in tab.pendingInserts {
            let cols = result.columns.map(\.name).filter { !autoInc.contains($0) && insert.values[$0] != nil }
            if cols.isEmpty {
                statements.append(session.engine == .mysql
                    ? "INSERT INTO \(table) () VALUES ();"
                    : "INSERT INTO \(table) DEFAULT VALUES;")
            } else {
                let colList = cols.map { session.quote($0) }.joined(separator: ", ")
                let valList = cols.map { literal(insert.values[$0]!, columnName: $0, result: result) }
                    .joined(separator: ", ")
                statements.append("INSERT INTO \(table) (\(colList)) VALUES (\(valList));")
            }
        }
        return statements
    }

    /// One entry per pending row (ungrouped), each independently revertible — backs
    /// the pending-changes panel where every change has its own discard button.
    func pendingChanges(_ tab: QueryTab) -> [PendingChange] {
        guard let session = tab.session, let source = tab.editSource, let result = tab.result else { return [] }
        let table = "\(session.quote(source.schema)).\(session.quote(source.table))"
        let keyColumns = source.primaryKeys.isEmpty ? result.columns.map(\.name) : source.primaryKeys
        var items: [PendingChange] = []

        for row in tab.pendingDeletes.sorted() {
            let clause = rowWhere(row, keyColumns: keyColumns, result: result, session: session)
            items.append(PendingChange(id: "d\(row)", target: .delete(row: row),
                                       statement: "DELETE FROM \(table) WHERE \(clause);"))
        }
        for (row, changes) in tab.edits.sorted(by: { $0.key < $1.key }) where !tab.pendingDeletes.contains(row) {
            let setClause = changes.sorted { $0.key < $1.key }
                .map { "\(session.quote($0.key)) = \(literal($0.value, columnName: $0.key, result: result))" }
                .joined(separator: ", ")
            let clause = rowWhere(row, keyColumns: keyColumns, result: result, session: session)
            items.append(PendingChange(id: "u\(row)", target: .update(row: row),
                                       statement: "UPDATE \(table) SET \(setClause) WHERE \(clause);"))
        }
        let autoInc = Set(source.autoIncrementColumns)
        for insert in tab.pendingInserts {
            let cols = result.columns.map(\.name).filter { !autoInc.contains($0) && insert.values[$0] != nil }
            let statement: String
            if cols.isEmpty {
                statement = session.engine == .mysql ? "INSERT INTO \(table) () VALUES ();"
                                                     : "INSERT INTO \(table) DEFAULT VALUES;"
            } else {
                let colList = cols.map { session.quote($0) }.joined(separator: ", ")
                let valList = cols.map { literal(insert.values[$0]!, columnName: $0, result: result) }
                    .joined(separator: ", ")
                statement = "INSERT INTO \(table) (\(colList)) VALUES (\(valList));"
            }
            items.append(PendingChange(id: "i\(insert.id)", target: .insert(id: insert.id), statement: statement))
        }
        return items
    }

    /// Discards a single pending change (from the panel's per-row × button).
    func revert(_ tab: QueryTab, _ target: PendingChange.Target) {
        switch target {
        case .update(let row): tab.edits[row] = nil
        case .delete(let row): tab.pendingDeletes.remove(row)
        case .insert(let id): tab.pendingInserts.removeAll { $0.id == id }
        }
    }

    /// WHERE clauses for the given rows: one `col IN (…)` when the key is a single
    /// column with no NULLs, otherwise one AND-clause per row.
    private func whereClauses(rows: [Int], keyColumns: [String], result: QueryResult,
                              session: ConnectionSession) -> [String] {
        if keyColumns.count == 1, let name = keyColumns.first,
           let index = result.columns.firstIndex(where: { $0.name == name }) {
            let values = rows.compactMap { row -> String? in
                guard row < result.rows.count, index < result.rows[row].count,
                      let text = result.rows[row][index].text else { return nil }
                return literal(text, columnName: name, result: result)
            }
            if values.count == rows.count, !values.isEmpty {
                return ["\(session.quote(name)) IN (\(values.joined(separator: ", ")))"]
            }
        }
        return rows.map { rowWhere($0, keyColumns: keyColumns, result: result, session: session) }
    }

    private func rowWhere(_ row: Int, keyColumns: [String], result: QueryResult,
                          session: ConnectionSession) -> String {
        keyColumns.compactMap { name -> String? in
            guard let index = result.columns.firstIndex(where: { $0.name == name }),
                  row < result.rows.count, index < result.rows[row].count else { return nil }
            let text = result.rows[row][index].text
            return text == nil ? "\(session.quote(name)) IS NULL"
                               : "\(session.quote(name)) = \(literal(text!, columnName: name, result: result))"
        }.joined(separator: " AND ")
    }

    /// A SQL literal for `value`, unquoted for numeric columns (so `id = 3`, not
    /// `id = '3'`) when the text is actually a number, quoted and escaped otherwise.
    private func literal(_ value: String, columnName: String, result: QueryResult) -> String {
        if let column = result.columns.first(where: { $0.name == columnName }),
           Self.isNumericType(column.typeName), Self.looksNumeric(value) {
            return value
        }
        return Self.literal(value)
    }

    private static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func isNumericType(_ typeName: String) -> Bool {
        let names: Set<String> = [
            // Postgres (PostgresDataType descriptions)
            "SMALLINT", "INTEGER", "BIGINT", "REAL", "DOUBLE PRECISION", "NUMERIC", "DECIMAL", "OID",
            // MySQL (MySQLProtocol.DataType descriptions)
            "MYSQL_TYPE_TINY", "MYSQL_TYPE_SHORT", "MYSQL_TYPE_LONG", "MYSQL_TYPE_INT24",
            "MYSQL_TYPE_LONGLONG", "MYSQL_TYPE_FLOAT", "MYSQL_TYPE_DOUBLE",
            "MYSQL_TYPE_DECIMAL", "MYSQL_TYPE_NEWDECIMAL", "MYSQL_TYPE_YEAR",
        ]
        return names.contains(typeName.uppercased())
    }

    private static func looksNumeric(_ text: String) -> Bool {
        text.range(of: #"^-?\d+(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil
    }

    /// Puts `SELECT *` into the active tab and runs it (from a spotlight navigation).
    func selectAll(schema: String, table: String) async {
        guard let session = activeSession else { return }
        if activeTab == nil { activateTab(for: session) }
        guard let tab = activeTab else { return }
        tab.sql = "SELECT * FROM \(session.quote(schema)).\(session.quote(table)) LIMIT 200;"
        await run(tab)
    }

    // MARK: Data views (schema-tree table browsing)

    /// Opens a dedicated data-view tab (grid + filter + paging, no SQL editor) for a
    /// table on the active connection. Double-clicking a table in the schema tree.
    func openTable(schema: String, table: String) async {
        guard let session = activeSession else { return }
        // Reuse an existing data view for the same table on this connection.
        if let existing = tabs.first(where: {
            $0.session === session && $0.kind == .data && $0.dataSchema == schema && $0.dataTable == table
        }) {
            activeTabID = existing.id
            return
        }
        let tab = QueryTab(title: table)
        tab.session = session
        tab.kind = .data
        tab.dataSchema = schema
        tab.dataTable = table
        tab.pageLimit = QueryTab.pageSize
        tabs.append(tab)
        activeTabID = tab.id
        await reloadData(tab, refreshCount: true)
    }

    /// Opens the table a foreign key points at, filtered to the referenced row —
    /// "follow this reference". Reuses an existing view of that table, replacing its
    /// filter so the same tab doesn't keep a stale one.
    func openReferencedTable(schema: String, table: String, where clause: String) async {
        await openTable(schema: schema, table: table)
        guard let tab = activeTab, tab.kind == .data else { return }
        tab.filterWhere = clause
        tab.sortColumn = nil
        tab.pageLimit = QueryTab.pageSize
        await reloadData(tab, refreshCount: true)
    }

    /// The generated `SELECT *` for a data view, folding in the filter, sort, and page limit.
    private func dataSQL(_ tab: QueryTab, limit: Int? = nil, offset: Int? = nil,
                         orderOverride: [String]? = nil) -> String {
        guard let session = tab.session, let schema = tab.dataSchema, let table = tab.dataTable else { return tab.sql }
        var sql = "SELECT * FROM \(session.quote(schema)).\(session.quote(table))"
        let filter = tab.filterWhere.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty { sql += " WHERE \(filter)" }
        if let column = tab.sortColumn {
            sql += " ORDER BY \(session.quote(column)) \(tab.sortAscending ? "ASC" : "DESC")"
        } else if let orderOverride, !orderOverride.isEmpty {
            sql += " ORDER BY " + orderOverride.map { session.quote($0) }.joined(separator: ", ")
        }
        sql += " LIMIT \(limit ?? tab.pageLimit)"
        if let offset, offset > 0 { sql += " OFFSET \(offset)" }
        return sql
    }

    /// A deterministic ordering for OFFSET paging. Without one the server may return
    /// rows in a different order per page, duplicating or skipping some; in that case
    /// we page by re-running with a bigger LIMIT instead.
    private func stableOrdering(for tab: QueryTab) -> [String]? {
        if tab.sortColumn != nil { return [] }        // already ordered by the user
        let keys = tab.editSource?.primaryKeys ?? []
        return keys.isEmpty ? nil : keys
    }

    /// Runs the data view's generated query; optionally refreshes the total count.
    func reloadData(_ tab: QueryTab, refreshCount: Bool = false) async {
        tab.sql = dataSQL(tab)
        await run(tab, sqlToRun: tab.sql, preserveSort: true)
        if refreshCount { await self.refreshCount(tab) }
    }

    /// Fetches `SELECT count(*)` for the current filter so the UI can show "N of TOTAL".
    private func refreshCount(_ tab: QueryTab) async {
        guard let session = tab.session, let driver = session.driver,
              let schema = tab.dataSchema, let table = tab.dataTable else { return }
        var sql = "SELECT count(*) FROM \(session.quote(schema)).\(session.quote(table))"
        let filter = tab.filterWhere.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty { sql += " WHERE \(filter)" }
        if let result = try? await driver.execute(sql), let text = result.rows.first?.first?.text,
           let count = Int(text.trimmingCharacters(in: .whitespaces)) {
            tab.totalRows = count
        } else {
            tab.totalRows = nil   // don't keep a stale total behind a failed/changed count
        }
    }

    /// "Load more" — fetches only the next page (via OFFSET) and appends it, so
    /// growing a large view doesn't refetch everything already on screen.
    /// No-op with pending changes so a reload can't silently discard them.
    func loadMore(_ tab: QueryTab) async {
        guard tab.kind == .data, !tab.hasEdits, !tab.isRunning,
              let session = tab.session, var existing = tab.result else { return }
        // Decide before claiming `isRunning`: the fallback re-runs the query, and
        // `run` refuses to start while the tab is already marked running.
        guard let ordering = stableOrdering(for: tab) else {
            // No stable order to page by — grow the window and re-run instead.
            tab.pageLimit += QueryTab.pageSize
            await reloadData(tab)
            return
        }
        tab.isRunning = true
        tab.errorMessage = nil
        defer { tab.isRunning = false }
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? "Not connected"
            return
        }
        let offset = existing.rows.count
        let sql = dataSQL(tab, limit: QueryTab.pageSize, offset: offset, orderOverride: ordering)
        do {
            let page = try await driver.execute(sql, maxRows: QueryTab.pageSize)
            guard !page.rows.isEmpty else { return }
            existing.rows.append(contentsOf: page.rows)
            existing.isTruncated = page.isTruncated
            tab.result = existing
            tab.resultVersion &+= 1
            tab.pageLimit = existing.rows.count
            tab.sql = dataSQL(tab)
        } catch {
            tab.errorMessage = ConnectionSession.message(for: error)
        }
    }

    /// Sets an explicit row limit for a data view (overrides the paging default) and re-runs.
    func setLimit(_ tab: QueryTab, _ limit: Int) async {
        guard tab.kind == .data, !tab.hasEdits else { return }
        tab.pageLimit = max(1, limit)
        await reloadData(tab)
    }

    /// Clears the active sort and re-runs.
    func clearSort(_ tab: QueryTab) async {
        guard tab.sortColumn != nil, let session = tab.session else { return }
        tab.sortColumn = nil
        if tab.kind == .data {
            await reloadData(tab)
        } else {
            tab.sql = rewriteOrderBy(tab.sql, column: nil, ascending: true, session: session)
            await run(tab, sqlToRun: tab.sql, preserveSort: true)
        }
    }

    /// Applies a new WHERE filter, resets paging, and refreshes the count.
    /// No-op with pending changes so a reload can't silently discard them.
    func applyFilter(_ tab: QueryTab, where clause: String) async {
        guard tab.kind == .data, !tab.hasEdits else { return }
        tab.filterWhere = clause
        tab.pageLimit = QueryTab.pageSize
        await reloadData(tab, refreshCount: true)
    }

    func loadIntoActiveTab(_ sql: String) {
        if let tab = activeTab {
            tab.sql = sql
        } else {
            addTab()
            activeTab?.sql = sql
        }
    }

    /// Re-introspects the active connection's schema (⌘R).
    func refreshSchema() async {
        await activeSession?.refreshSchema()
    }

    // MARK: History

    /// Applies a schema change on the active connection and re-introspects, so the
    /// tree reflects it right away. Returns an error message on failure.
    func runDDL(_ sql: String) async -> String? {
        guard let session = activeSession else { return "Not connected" }
        guard await ensureReady(session), let driver = session.driver else {
            return session.errorMessage ?? "Not connected"
        }
        do {
            _ = try await driver.execute(sql)
            recordHistory(sql: sql, session: session, rowCount: 0, elapsedMS: nil)
            await session.refreshSchema()
            return nil
        } catch {
            return ConnectionSession.message(for: error)
        }
    }

    /// Stops a running query: cancels the client task *and* asks the server to abort
    /// it, so a heavy query doesn't keep burning resources after Stop.
    func cancel(_ tab: QueryTab) async {
        tab.task?.cancel()
        await tab.session?.driver?.cancelRunningQuery()
    }

    /// Empties the query history (and its on-disk store).
    func clearHistory() {
        history = []
        let store = historyStore
        Task.detached { store.save([]) }
    }

    // MARK: Saved queries

    /// Bookmarks `sql` under `title` (newest first) and persists.
    func saveQuery(title: String, sql: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let entry = SavedQuery(title: name.isEmpty ? String(localized: "Untitled") : name,
                               sql: sql, createdAt: Date())
        savedQueries.insert(entry, at: 0)
        persistSavedQueries()
    }

    func deleteSavedQuery(_ id: UUID) {
        savedQueries.removeAll { $0.id == id }
        persistSavedQueries()
    }

    private func persistSavedQueries() {
        let snapshot = savedQueries
        let store = savedQueryStore
        Task.detached { store.save(snapshot) }
    }

    private func recordHistory(sql: String, session: ConnectionSession, rowCount: Int, elapsedMS: Int?,
                               schema: String? = nil, table: String? = nil) {
        // Collapse a re-run of the identical query on the same connection (e.g.
        // refreshing a table view) into the existing entry instead of duplicating it.
        if let first = history.first, first.sql == sql, first.profileID == session.id, first.table == table {
            history[0].timestamp = Date()
            history[0].rowCount = rowCount
            history[0].elapsedMS = elapsedMS
        } else {
            let entry = QueryHistoryEntry(
                sql: sql, connectionName: session.name, profileID: session.id,
                schema: schema, table: table, timestamp: Date(),
                rowCount: rowCount, elapsedMS: elapsedMS)
            history.insert(entry, at: 0)
            if history.count > 500 { history = Array(history.prefix(500)) }
        }
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
}
