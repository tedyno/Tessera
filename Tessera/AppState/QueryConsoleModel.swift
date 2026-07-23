import SwiftUI
import AppKit
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

    /// Tiling: how the tabs are grouped into panes. The `QueryTab` objects stay in
    /// `tabs`; the workspace only arranges their ids into groups and splits.
    let workspace = WorkspaceLayout()

    /// The `QueryTab` for an id, and the tabs of a group in their group order.
    func tab(_ id: UUID) -> QueryTab? { tabs.first { $0.id == id } }
    func tabs(in group: TabGroup) -> [QueryTab] { group.tabIDs.compactMap(tab) }
    func activeTab(in group: TabGroup) -> QueryTab? { group.activeID.flatMap(tab) }

    /// The schema/engine a specific tab edits against — its own connection's, so a
    /// pane's editor completes against the right database even when another pane is
    /// focused. Falls back to the cached schema when disconnected.
    func schema(for tab: QueryTab) -> DatabaseTree? {
        guard let session = tab.session else { return nil }
        return session.schema ?? cachedSchemaProvider?(session.id)
    }
    func engine(for tab: QueryTab) -> DatabaseKind? { tab.session?.engine }

    private(set) var history: [QueryHistoryEntry] = []
    private let historyStore: QueryHistoryStore

    /// Diagnostics for connection attempts, shown from the status bar.
    let connectionLog = ConnectionLog()

    /// User-bookmarked SQL snippets, newest first.
    private(set) var savedQueries: [SavedQuery] = []
    private let savedQueryStore: SavedQueryStore

    /// Injected by `AppModel`: reconnects a dropped session (it needs Keychain
    /// secrets, which live outside the console). Lets a run auto-reconnect first.
    var reconnect: (ConnectionSession) async -> Void = { _ in }

    /// Ensures the session is live, reconnecting on demand, before a query runs.
    /// Touches the session's activity clock on success, resetting the idle timer.
    private func ensureReady(_ session: ConnectionSession) async -> Bool {
        if !session.isReady, !session.isConnecting { await reconnect(session) }
        guard session.isReady else { return false }
        session.touch()
        return true
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
    /// The connection picked in the organizer. Selecting one used to fabricate an
    /// empty query tab purely so the schema sidebar had a session to read; this holds
    /// it instead, so connecting can leave the workspace empty until you open a table.
    private(set) var currentSession: ConnectionSession?

    /// The connection currently in focus: the one last picked in the organizer, which
    /// switching tabs keeps in sync. Picking a connection therefore updates the schema
    /// tree even while a tab from another one is open.
    var activeSession: ConnectionSession? { currentSession ?? activeTab?.session }

    /// Makes a connection current without opening anything.
    func selectSession(_ session: ConnectionSession) { currentSession = session }

    /// Switches to a tab and moves the connection focus with it, so the schema tree
    /// always belongs to what you are looking at. Set explicitly rather than through
    /// a `didSet` on `activeTabID`: property observers inside `@Observable` are a
    /// trap, and every internal caller here needs the focus updated anyway.
    func activate(_ tab: QueryTab) {
        // The value-editor sheet is presented off the *active* tab; leaving it
        // open on a background tab would re-present a stale target on return.
        if activeTabID != tab.id { activeTab?.valueEditor = nil }
        activeTabID = tab.id
        if let session = tab.session { currentSession = session }
        // Keep the tiling layout in step: the tab's pane takes focus and shows it,
        // and a tab that isn't in any group yet (freshly opened) joins the focused
        // one. Every open/create path funnels through here, so this is the single
        // point that registers tabs with the workspace.
        if let group = workspace.group(containing: tab.id) {
            group.activeID = tab.id
            workspace.focusedGroupID = group.id
        } else {
            workspace.add(tabID: tab.id)
        }
    }

    /// Drops a connection that no longer exists: closes it, closes its tabs, and
    /// clears it as the current one so nothing keeps pointing at a deleted profile.
    func forgetSession(profileID: UUID) {
        guard let session = session(for: profileID) else { return }
        let doomed = tabs.filter { $0.session === session }
        for tab in doomed { tab.task?.cancel() }
        tabs.removeAll { $0.session === session }
        for tab in doomed { workspace.remove(tabID: tab.id) }
        if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = workspace.focusedGroup?.activeID ?? tabs.last?.id
        }
        if currentSession === session { currentSession = nil }
        sessions.removeAll { $0 === session }
        Task { await session.close() }
    }

    /// Connection state of the active tab's session, surfaced for the status bar.
    var status: ConnectionSession.Status { activeSession?.status ?? .idle }
    /// Fallback for sessions with no live schema: the persisted per-profile
    /// schema cache (the one search already uses). Set by AppModel.
    @ObservationIgnored var cachedSchemaProvider: ((UUID) -> DatabaseTree?)?
    /// The live schema when connected, else the last introspected one from the
    /// cache — the sidebar and diagrams work without a connection.
    var schema: DatabaseTree? {
        guard let session = activeSession else { return nil }
        return session.schema ?? cachedSchemaProvider?(session.id)
    }
    /// True when `schema` comes from the cache, so the UI can say so.
    var isShowingCachedSchema: Bool {
        activeSession?.schema == nil && schema != nil
    }
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
        session.log = connectionLog
        sessions.append(session)
        return session
    }

    /// Activates the session's most recent tab, creating a console tab if it has none.
    func activateTab(for session: ConnectionSession) {
        if let tab = tabs.last(where: { $0.session === session }) {
            activate(tab)
        } else {
            let tab = QueryTab(title: "Query 1")
            tab.session = session
            tabs.append(tab)
            activate(tab)
        }
    }

    // MARK: Tabs

    /// Opens a console tab. Coming from a table view it starts prefilled with the
    /// query behind that view — handy for tweaking a filter or adding a join — but
    /// deliberately isn't run, so nothing hits the database until you ask.
    func addTab(boundTo session: ConnectionSession? = nil) {
        let tab = QueryTab(title: "Query \(tabs.count + 1)")
        let source = activeTab
        // A new tab opened over a data view belongs to that view's connection and
        // starts from its generated query — regardless of which connection the
        // organizer happens to have highlighted at the moment (a mere click there
        // moves `currentSession` without the data view changing at all).
        let target = session
            ?? (source?.kind == .data ? source?.session : nil)
            ?? activeSession ?? sessions.last
        tab.session = target
        if let source, source.kind == .data, source.session === target,
           !source.sql.isEmpty {
            tab.sql = source.sql
        }
        tabs.append(tab)
        activate(tab)
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.task?.cancel()
        tab.autoRefreshTask?.cancel()
        tabs.removeAll { $0.id == id }
        workspace.remove(tabID: id)   // drops it from its pane, collapsing an empty one
        if activeTabID == id { activeTabID = workspace.focusedGroup?.activeID ?? tabs.last?.id }
    }

    /// Closes every tab whose id is in `ids`, cancelling anything they were running.
    private func closeTabs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for tab in tabs where ids.contains(tab.id) {
            tab.task?.cancel()
            tab.autoRefreshTask?.cancel()
        }
        tabs.removeAll { ids.contains($0.id) }
        for id in ids { workspace.remove(tabID: id) }
        if let active = activeTabID, ids.contains(active) {
            activeTabID = workspace.focusedGroup?.activeID ?? tabs.last?.id
        }
    }

    /// Closes a whole pane (its tab group) and every tab in it. `closeTabs` already
    /// reconciles `activeTabID` (only if the active tab was among the closed ones),
    /// so closing a background pane leaves the focus where it was.
    func closePane(_ groupID: UUID) {
        let ids = workspace.closeGroup(groupID)
        closeTabs(Set(ids))
    }

    /// The tab-menu "close others/left/right" now scope to the tab's own pane.
    func closeOtherTabs(_ id: UUID) {
        guard let group = workspace.group(containing: id) else { return }
        closeTabs(Set(group.tabIDs.filter { $0 != id }))
    }

    func closeAllTabs() {
        closeTabs(Set(tabs.map(\.id)))
    }

    func closeTabsToLeft(of id: UUID) {
        guard let group = workspace.group(containing: id),
              let index = group.tabIDs.firstIndex(of: id) else { return }
        closeTabs(Set(group.tabIDs[..<index]))
    }

    func closeTabsToRight(of id: UUID) {
        guard let group = workspace.group(containing: id),
              let index = group.tabIDs.firstIndex(of: id) else { return }
        closeTabs(Set(group.tabIDs[(index + 1)...]))
    }

    /// Reorders `draggedID` to sit just before `targetID` within their shared pane.
    /// Only reorders inside one group — cross-group moves happen via a split drop.
    func moveTab(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let group = workspace.group(containing: targetID),
              group.tabIDs.contains(draggedID) else { return }
        group.tabIDs.removeAll { $0 == draggedID }
        let insertAt = group.tabIDs.firstIndex(of: targetID) ?? group.tabIDs.count
        group.tabIDs.insert(draggedID, at: insertAt)
    }

    /// Reorders `draggedID` to the end of its own pane.
    func moveTabToEnd(_ draggedID: UUID) {
        guard let group = workspace.group(containing: draggedID) else { return }
        group.tabIDs.removeAll { $0 == draggedID }
        group.tabIDs.append(draggedID)
    }

    /// Drops `draggedID` into `group` (a drop on another pane's tab bar). Within the
    /// same pane it reorders; across panes it moves the tab over — collapsing the
    /// source pane if that empties it. `before` places it before that tab, else last.
    func moveTab(_ draggedID: UUID, toGroup group: TabGroup, before targetID: UUID?) {
        guard let from = workspace.group(containing: draggedID) else { return }
        if from === group {
            if let targetID { moveTab(draggedID, before: targetID) } else { moveTabToEnd(draggedID) }
            return
        }
        workspace.remove(tabID: draggedID)   // pull from the old pane (collapse if empty)
        let insertAt = targetID.flatMap { group.tabIDs.firstIndex(of: $0) } ?? group.tabIDs.count
        group.tabIDs.insert(draggedID, at: min(insertAt, group.tabIDs.count))
        group.activeID = draggedID
        workspace.focusedGroupID = group.id
        activeTabID = draggedID
    }

    /// Drag-drop onto a pane edge: splits `targetGroupID` and moves `draggedID` into
    /// a fresh group on that side. If it was the only tab in its old pane, that pane
    /// collapses. Ignores a drop back onto the tab's own solo pane.
    func splitDrop(_ draggedID: UUID, into targetGroupID: UUID, edge: DropEdge) {
        if let from = workspace.group(containing: draggedID),
           from.id == targetGroupID, from.tabIDs.count == 1 { return }
        workspace.splitDropping(tabID: draggedID, targetGroupID: targetGroupID, edge: edge)
        activeTabID = draggedID
    }

    /// The pane's "+" — a new console tab that lands in that specific group.
    func addTab(in group: TabGroup, boundTo session: ConnectionSession? = nil) {
        workspace.focusedGroupID = group.id
        addTab(boundTo: session)
    }

    /// After a restore that appended tabs straight into `tabs`, fold any that aren't
    /// in a group yet into the focused pane, preserving order.
    func adoptRestoredTabs() {
        for tab in tabs where workspace.group(containing: tab.id) == nil {
            workspace.add(tabID: tab.id)
        }
        if let id = activeTabID, let group = workspace.group(containing: id) {
            group.activeID = id
            workspace.focusedGroupID = group.id
        }
    }

    /// Whether there is anything to close on that side, within the pane, so the tab
    /// menu can grey out items that would do nothing.
    func hasTabs(toLeftOf id: UUID) -> Bool {
        guard let group = workspace.group(containing: id) else { return false }
        return (group.tabIDs.firstIndex(of: id)).map { $0 > 0 } ?? false
    }

    func hasTabs(toRightOf id: UUID) -> Bool {
        guard let group = workspace.group(containing: id) else { return false }
        return (group.tabIDs.firstIndex(of: id)).map { $0 < group.tabIDs.count - 1 } ?? false
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

    func run(_ tab: QueryTab, sqlToRun: String? = nil, preserveSort: Bool = false,
             preserveSearch: Bool = false) async {
        guard let session = tab.session, !tab.isRunning else { return }
        let sql = sqlToRun ?? tab.sql
        let clock = ContinuousClock()
        let started = clock.now
        if !preserveSort { tab.sortOrder = [] }
        tab.isRunning = true
        tab.errorMessage = nil
        // Reconnect a dropped connection first, then run.
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? "Not connected"
            tab.isRunning = false
            return
        }
        do {
            // A data view honors its own "Limit" field — an explicit row count the
            // user asked for is never clipped by the global Max-rows safety cap,
            // which only bounds free-form query results.
            let cap = tab.kind == .data ? tab.pageLimit : ExportSettings.maxRows
            var result = try await driver.execute(sql, maxRows: cap > 0 ? cap : nil)
            // Both drivers derive column info from the fetched rows, so a query that
            // legitimately matches zero rows comes back with no columns at all — no
            // grid, no headers, and (for an editable table) `detectEditSource` below
            // would wrongly see it as uneditable too. A data-view tab already knows
            // its table's columns from the introspected schema; fall back to those.
            if result.columns.isEmpty, result.rows.isEmpty, tab.kind == .data,
               let schemaName = tab.dataSchema, let tableName = tab.dataTable,
               let table = session.schema?.schemas.first(where: { $0.name == schemaName })?
                   .tables.first(where: { $0.name == tableName }) {
                result.columns = table.columns.map { ColumnDescriptor(name: $0.name, typeName: $0.dataType) }
            }
            tab.result = result
            // Truncation means the fetch stopped at the limit and more rows exist —
            // the signal for "Load more" and infinite scroll.
            tab.hasMoreRows = tab.kind == .data && result.isTruncated
            tab.resultVersion &+= 1
            tab.currentPlan = (tab.expectedPlan?.sql == sql) ? tab.expectedPlan : nil
            tab.expectedPlan = nil
            tab.showRawPlan = false
            tab.scriptSummary = nil
            tab.edits = [:]
            tab.pendingDeletes = []
            tab.pendingInserts = []
            tab.clearEditHistory()   // snapshots index into the replaced result
            if !preserveSearch {
                tab.clearSearch()   // a stale ⌘F filter over the old result would
                                    // otherwise silently block editing on the new one
            }
            tab.editSource = detectEditSource(sql: sql, columns: result.columns, schema: session.schema)
            let ms = result.elapsed.map(Self.milliseconds)
            tab.elapsedMS = ms
            recordHistory(sql: sql, session: session, rowCount: result.rows.count, elapsedMS: ms,
                          schema: tab.kind == .data ? tab.dataSchema : nil,
                          table: tab.kind == .data ? tab.dataTable : nil)
        } catch {
            tab.errorMessage = ConnectionSession.message(for: error)
            tab.expectedPlan = nil
        }
        tab.isRunning = false
        Self.bounceDockIfLong(started, clock: clock)
    }

    /// A long query that finished while the app was in the background deserves a
    /// nudge — one Dock bounce, which needs no notification permissions.
    private static func bounceDockIfLong(_ started: ContinuousClock.Instant, clock: ContinuousClock) {
        guard clock.now - started >= .seconds(10), !NSApplication.shared.isActive else { return }
        NSApplication.shared.requestUserAttention(.informationalRequest)
    }

    /// Runs a multi-statement script (e.g. a loaded `.sql` file) against the tab's
    /// session, statement by statement, stopping on the first error. Shows the last
    /// result; on failure reports which statement failed.
    func runScript(_ tab: QueryTab) async {
        guard let session = tab.session, !tab.isRunning else { return }
        let statements = SQLScript.statements(in: tab.sql)
        guard !statements.isEmpty else { return }
        let clock = ContinuousClock()
        let started = clock.now
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
            tab.expectedPlan = nil
            tab.currentPlan = nil
            tab.edits = [:]; tab.pendingDeletes = []; tab.pendingInserts = []
            tab.clearEditHistory()
            tab.clearSearch()
            tab.editSource = nil   // a script isn't a single editable table view
            tab.scriptSummary = "Executed \(executed) statement\(executed == 1 ? "" : "s")"
        } catch {
            tab.scriptSummary = nil
            tab.errorMessage = "Statement \(executed + 1) of \(statements.count) failed:\n"
                + ConnectionSession.message(for: error)
        }
        tab.isRunning = false
        Self.bounceDockIfLong(started, clock: clock)
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
            tab.clearEditHistory()   // undo must not resurrect already-committed changes
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
        // Only a plain full-table view is editable — and it must *start* with
        // SELECT: an EXPLAIN of the same query also "contains" it, and a MySQL plan
        // happens to expose an `id` column, which would make the plan grid look
        // editable and target the real table on commit.
        guard upper.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SELECT"),
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
        tab.captureEditSnapshot()
        tab.pendingInserts.append(PendingInsert())
    }

    /// Drops every pending edit, delete, and insert without touching the database.
    /// Undoable — Discard All shouldn't be able to eat a batch of edits for good.
    func discardPending(_ tab: QueryTab) {
        tab.captureEditSnapshot()
        tab.edits = [:]
        tab.pendingDeletes = []
        tab.pendingInserts = []
    }

    /// Header-click sorting on a full-table view: cycles ascending → descending →
    /// off for the clicked column, rewriting the query's `ORDER BY` and re-running.
    func sortByColumn(_ tab: QueryTab, column: String) async {
        // Data views sort server-side whether editable or read-only windowed; a
        // free-form single-table SELECT (editable) rewrites its own ORDER BY.
        guard tab.isEditable || tab.kind == .data, !tab.hasEdits, let session = tab.session else { return }
        // Cycle this column: absent → append ascending (next-lowest priority);
        // ascending → descending; descending → removed. Other columns keep their
        // place, so successive clicks build up a multi-column sort.
        if let index = tab.sortOrder.firstIndex(where: { $0.column == column }) {
            if tab.sortOrder[index].ascending {
                tab.sortOrder[index].ascending = false
            } else {
                tab.sortOrder.remove(at: index)
            }
        } else {
            tab.sortOrder.append(QueryTab.SortKey(column: column, ascending: true))
        }
        if tab.kind == .data {
            await reloadData(tab)   // rebuilds the generated query with the new ORDER BY
            return
        }
        let newSQL = rewriteOrderBy(tab.sql, sortOrder: tab.sortOrder, session: session)
        tab.sql = newSQL
        await run(tab, sqlToRun: newSQL, preserveSort: true)
    }

    /// Replaces the top-level `ORDER BY` of a full-table query (inserted before any
    /// `LIMIT`/`OFFSET`/`;`). An empty `sortOrder` removes ordering entirely. Matching
    /// ignores text inside string literals, so a WHERE value like `'a limit b'` is safe.
    private func rewriteOrderBy(_ sql: String, sortOrder: [QueryTab.SortKey],
                                session: ConnectionSession) -> String {
        var body = sql
        if let existing = Self.topLevelRange(
            in: body, pattern: #"(?is)\s+ORDER\s+BY\s+.*?(?=(\s+LIMIT\b|\s+OFFSET\b|\s*;\s*$|$))"#) {
            body.removeSubrange(existing)
        }
        guard !sortOrder.isEmpty else { return body }
        let clause = " ORDER BY " + sortOrder
            .map { "\(session.quote($0.column)) \($0.ascending ? "ASC" : "DESC")" }
            .joined(separator: ", ")
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
        var groups: [String: (changes: [String: String?], rows: [Int])] = [:]
        for (row, changes) in tab.edits where !tab.pendingDeletes.contains(row) {
            // "s"/"n" prefix keeps a cell set to NULL distinct from any real text.
            let key = changes.sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1}\($0.value.map { "s\($0)" } ?? "n")" }.joined(separator: "\u{2}")
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
                statements.append(session.engine.dialect.emptyInsert(table: table))
            } else {
                let colList = cols.map { session.quote($0) }.joined(separator: ", ")
                let valList = cols.map { literal(insert.values[$0]!, columnName: $0, result: result) }
                    .joined(separator: ", ")
                statements.append("INSERT INTO \(table) (\(colList)) VALUES (\(valList));")
            }
        }
        return statements
    }

    /// The panel's entries — the exact statements ⌘↩ will run, grouped the
    /// same way `pendingStatements` groups them (identical change-sets share
    /// one `WHERE pk IN (…)` UPDATE); discarding a group reverts all its rows.
    func pendingChanges(_ tab: QueryTab) -> [PendingChange] {
        guard let session = tab.session, let source = tab.editSource, let result = tab.result else { return [] }
        let table = "\(session.quote(source.schema)).\(session.quote(source.table))"
        let keyColumns = source.primaryKeys.isEmpty ? result.columns.map(\.name) : source.primaryKeys
        var items: [PendingChange] = []

        /// One item when the rows collapsed into a single IN clause, else one
        /// per row — mirroring what `whereClauses` produced.
        func append(rows: [Int], clauses: [String], id: (String) -> String,
                    target: ([Int]) -> PendingChange.Target, statement: (String) -> String) {
            if clauses.count == 1, rows.count > 1 {
                items.append(PendingChange(id: id(rows.map(String.init).joined(separator: "-")),
                                           target: target(rows), statement: statement(clauses[0])))
            } else {
                for (row, clause) in zip(rows, clauses) {
                    items.append(PendingChange(id: id(String(row)), target: target([row]),
                                               statement: statement(clause)))
                }
            }
        }

        let deleteRows = tab.pendingDeletes.sorted()
        if !deleteRows.isEmpty {
            append(rows: deleteRows,
                   clauses: whereClauses(rows: deleteRows, keyColumns: keyColumns,
                                         result: result, session: session),
                   id: { "d\($0)" }, target: { .delete(rows: $0) },
                   statement: { "DELETE FROM \(table) WHERE \($0);" })
        }

        var groups: [String: (changes: [String: String?], rows: [Int])] = [:]
        for (row, changes) in tab.edits where !tab.pendingDeletes.contains(row) {
            let key = changes.sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1}\($0.value.map { "s\($0)" } ?? "n")" }.joined(separator: "\u{2}")
            groups[key, default: (changes, [])].rows.append(row)
        }
        for group in groups.values.sorted(by: { ($0.rows.min() ?? 0) < ($1.rows.min() ?? 0) }) {
            let setClause = group.changes.sorted { $0.key < $1.key }
                .map { "\(session.quote($0.key)) = \(literal($0.value, columnName: $0.key, result: result))" }
                .joined(separator: ", ")
            let rows = group.rows.sorted()
            append(rows: rows,
                   clauses: whereClauses(rows: rows, keyColumns: keyColumns,
                                         result: result, session: session),
                   id: { "u\($0)" }, target: { .update(rows: $0) },
                   statement: { "UPDATE \(table) SET \(setClause) WHERE \($0);" })
        }
        let autoInc = Set(source.autoIncrementColumns)
        for insert in tab.pendingInserts {
            let cols = result.columns.map(\.name).filter { !autoInc.contains($0) && insert.values[$0] != nil }
            let statement: String
            if cols.isEmpty {
                statement = session.engine.dialect.emptyInsert(table: table)
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

    /// Discards one pending change (from the panel's × button) — a grouped
    /// statement reverts every row it covers, in one undo step.
    func revert(_ tab: QueryTab, _ target: PendingChange.Target) {
        tab.captureEditSnapshot()
        switch target {
        case .update(let rows): for row in rows { tab.edits[row] = nil }
        case .delete(let rows): for row in rows { tab.pendingDeletes.remove(row) }
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

    /// A SQL literal for `value`: `NULL` for nil (a cell explicitly set to NULL),
    /// unquoted for numeric columns (so `id = 3`, not `id = '3'`) when the text is
    /// actually a number, quoted and escaped otherwise.
    private func literal(_ value: String?, columnName: String, result: QueryResult) -> String {
        guard let value else { return "NULL" }
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

    // MARK: Data views (schema-tree table browsing)

    /// Opens a dedicated data-view tab (grid + filter + paging, no SQL editor) for a
    /// table on the active connection. Double-clicking a table in the schema tree.
    /// `on` names the connection explicitly. Without it the active *tab* decides,
    /// which is wrong when opening a search hit that belongs to another connection.
    func openTable(schema: String, table: String, on session: ConnectionSession? = nil) async {
        guard let session = session ?? activeSession else { return }
        // Reuse an existing data view for the same table on this connection.
        if let existing = tabs.first(where: {
            $0.session === session && $0.kind == .data && $0.dataSchema == schema && $0.dataTable == table
        }) {
            activate(existing)
            return
        }
        let tab = QueryTab(title: table)
        tab.session = session
        tab.kind = .data
        tab.dataSchema = schema
        tab.dataTable = table
        tab.pageLimit = QueryTab.defaultPageLimit
        tabs.append(tab)
        activate(tab)
        await reloadData(tab, refreshCount: true)
    }

    /// Opens the table a foreign key points at, filtered to the referenced row —
    /// "follow this reference". Reuses an existing view of that table, replacing its
    /// filter so the same tab doesn't keep a stale one.
    func openReferencedTable(schema: String, table: String, where clause: String) async {
        // Stays on the tab's own connection — a foreign key never crosses databases.
        await openTable(schema: schema, table: table, on: activeSession)
        guard let tab = activeTab, tab.kind == .data else { return }
        tab.filterWhere = clause
        tab.sortOrder = []
        tab.pageLimit = QueryTab.defaultPageLimit
        await reloadData(tab, refreshCount: true)
    }

    /// Opens (or refocuses) an ER-diagram tab on a connection. A table scope
    /// shows just that table and its direct FK neighbors; the schema scope
    /// shows everything. Pure canvas over the already-introspected schema — no
    /// query runs.
    func openDiagram(schema: String, scope: DiagramModel.Scope = .schema,
                     on session: ConnectionSession? = nil) {
        guard let session = session ?? activeSession else { return }
        // Disconnected sessions fall back to the cached schema — a diagram is
        // a pure canvas over introspected metadata, no connection needed.
        let tree = session.schema ?? cachedSchemaProvider?(session.id)
        let namespace = tree?.schemas.first(where: { $0.name == schema })
        if let existing = tabs.first(where: {
            $0.session === session && $0.kind == .diagram
                && $0.diagram?.schemaName == schema && $0.diagram?.scope == scope
        }) {
            // Re-introspection (DDL, ⌘R, database switch) invalidates the
            // snapshot — rebuild rather than focus a table that isn't in it.
            if let namespace, existing.diagram?.entities != namespace.tables {
                existing.diagram = DiagramModel(schemaName: schema, namespace: namespace,
                                                scope: scope)
            }
            focus(existing.diagram)
            activate(existing)
            return
        }
        guard let namespace else { return }
        let title: String = if case .table(let table) = scope { table } else { schema }
        let tab = QueryTab(title: title)
        tab.session = session
        tab.kind = .diagram
        tab.diagram = DiagramModel(schemaName: schema, namespace: namespace, scope: scope)
        focus(tab.diagram)
        tabs.append(tab)
        activate(tab)
    }

    private func focus(_ diagram: DiagramModel?) {
        guard let diagram, case .table(let table) = diagram.scope,
              diagram.entitiesByName[table] != nil else { return }
        diagram.focusTable = table
        diagram.selectedTable = table
    }

    /// The generated `SELECT *` for a data view, folding in the filter, sort, and page limit.
    private func dataSQL(_ tab: QueryTab, limit: Int? = nil, offset: Int? = nil,
                         orderOverride: [String]? = nil, unlimited: Bool = false) -> String {
        guard let session = tab.session, let schema = tab.dataSchema, let table = tab.dataTable else { return tab.sql }
        var sql = "SELECT * FROM \(session.quote(schema)).\(session.quote(table))"
        let filter = tab.filterWhere.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty { sql += " WHERE \(filter)" }
        if !tab.sortOrder.isEmpty {
            sql += " ORDER BY " + tab.sortOrder
                .map { "\(session.quote($0.column)) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
        } else if let orderOverride, !orderOverride.isEmpty {
            sql += " ORDER BY " + orderOverride.map { session.quote($0) }.joined(separator: ", ")
        }
        // A streamed export wants the whole table, so it omits the paging cap.
        if !unlimited {
            sql += " LIMIT \(limit ?? tab.pageLimit)"
            if let offset, offset > 0 { sql += " OFFSET \(offset)" }
        }
        return sql
    }

    /// SQL that yields the full intended result for a streamed export: a data
    /// view's whole table (respecting its filter/sort but no paging LIMIT), or a
    /// free-form tab's query exactly as written.
    func exportSQL(_ tab: QueryTab) -> String {
        tab.kind == .data ? dataSQL(tab, unlimited: true) : tab.sql
    }

    /// Streams the tab's full result to `url` as CSV or SQL, bypassing the row cap
    /// so nothing is buffered in memory. Returns `true` on success.
    func streamExport(_ tab: QueryTab, format: StreamingResultExport.Format,
                      table: String?, to url: URL) async -> Bool {
        guard let session = tab.session else { return false }
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? "Not connected"
            return false
        }
        do {
            _ = try await StreamingResultExport.export(exportSQL(tab), from: driver,
                                                       format: format, table: table ?? "table", to: url)
            return true
        } catch {
            tab.errorMessage = "Could not write \(url.lastPathComponent): "
                + ConnectionSession.message(for: error)
            return false
        }
    }

    /// A deterministic ordering for OFFSET paging. Without one the server may return
    /// rows in a different order per page, duplicating or skipping some. Only the
    /// primary key qualifies — physical row ids (`ctid`/`rowid`) aren't universal
    /// (views, and Postgres compressed/foreign tables reject `ctid`), so a keyless
    /// table isn't windowed; it just honors its explicit row limit, buffered.
    private func stableOrdering(for tab: QueryTab) -> [String]? {
        if !tab.sortOrder.isEmpty { return [] }       // already ordered by the user
        let keys = tab.editSource?.primaryKeys ?? []
        return keys.isEmpty ? nil : keys
    }

    /// Runs the data view's generated query; optionally refreshes the total count.
    func reloadData(_ tab: QueryTab, refreshCount: Bool = false, preserveSearch: Bool = false) async {
        tab.sql = dataSQL(tab)
        await run(tab, sqlToRun: tab.sql, preserveSort: true, preserveSearch: preserveSearch)
        if refreshCount { await self.refreshCount(tab) }
    }

    // MARK: Auto-refresh

    /// Re-runs the tab on a fixed cadence (nil turns it off). A cycle is skipped —
    /// not stopped — while the tab is busy or has unsaved edits, and the ⌘F filter
    /// survives each refresh (its bar is visible, unlike the stale-filter case a
    /// manual run clears).
    func setAutoRefresh(_ tab: QueryTab, interval: TimeInterval?) {
        guard tab.kind != .diagram else { return }
        tab.autoRefreshTask?.cancel()
        tab.autoRefreshTask = nil
        tab.autoRefreshInterval = interval
        guard let interval else { return }
        // Console tabs re-run the statement under the cursor as of now — not
        // whatever the editor happens to say later, mid-edit.
        var consoleSQL: String?
        if tab.kind == .console {
            switch resolveRunTarget(tab) {
            case .statement(let statement): consoleSQL = statement.isEmpty ? tab.sql : statement
            case .ambiguous(let choice): consoleSQL = choice.statement
            }
        }
        let sql = consoleSQL
        tab.autoRefreshTask = Task { [weak self, weak tab] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, let tab, !Task.isCancelled else { return }
                // A live cell-edit session has no committed edits yet, so it needs
                // its own guard — replacing the result under it would make the edit
                // commit against shifted row indices.
                guard !tab.isRunning, !tab.hasEdits, !tab.isEditingCell,
                      tab.valueEditor == nil else { continue }
                if tab.kind == .data {
                    await self.reloadData(tab, preserveSearch: true)
                } else if let sql {
                    await self.run(tab, sqlToRun: sql, preserveSort: true, preserveSearch: true)
                }
            }
        }
    }

    /// Fetches `SELECT count(*)` for the current filter so the UI can show "N of TOTAL".
    private func refreshCount(_ tab: QueryTab) async {
        guard let session = tab.session, let driver = session.driver,
              let schema = tab.dataSchema, let table = tab.dataTable else { return }
        session.touch()
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
            guard !page.rows.isEmpty else { tab.hasMoreRows = false; return }
            existing.rows.append(contentsOf: page.rows)
            existing.isTruncated = page.isTruncated
            tab.result = existing
            tab.hasMoreRows = page.isTruncated   // a full page means more may follow
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
        tab.pageLimit = QueryTab.clampedPageLimit(limit)
        await reloadData(tab)
    }

    /// Clears the active sort and re-runs.
    func clearSort(_ tab: QueryTab) async {
        guard !tab.sortOrder.isEmpty, let session = tab.session else { return }
        tab.sortOrder = []
        if tab.kind == .data {
            await reloadData(tab)
        } else {
            tab.sql = rewriteOrderBy(tab.sql, sortOrder: [], session: session)
            await run(tab, sqlToRun: tab.sql, preserveSort: true)
        }
    }

    /// Applies a new WHERE filter, resets paging, and refreshes the count.
    /// No-op with pending changes so a reload can't silently discard them.
    func applyFilter(_ tab: QueryTab, where clause: String) async {
        guard tab.kind == .data, !tab.hasEdits else { return }
        tab.filterWhere = clause
        tab.pageLimit = QueryTab.defaultPageLimit
        await reloadData(tab, refreshCount: true)
    }

    func loadIntoActiveTab(_ sql: String) {
        // A data view's SQL is generated from its filters — loading a saved query
        // over it would corrupt the view, so those get a fresh console tab on the
        // same connection instead.
        if let tab = activeTab, tab.kind == .console {
            tab.sql = sql
        } else {
            addTab(boundTo: activeTab?.session)
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

    /// Bookmarks `sql` under `title` (newest first) and persists, bound to the
    /// active tab's connection — a query only makes sense against its schema.
    func saveQuery(title: String, sql: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let entry = SavedQuery(title: name.isEmpty ? String(localized: "Untitled") : name,
                               sql: sql, createdAt: Date(),
                               connectionID: activeTab?.session?.id)
        savedQueries.insert(entry, at: 0)
        persistSavedQueries()
    }

    /// Saved queries for the active tab's connection, plus legacy entries saved
    /// before queries were connection-bound (connectionID == nil).
    var savedQueriesForActiveConnection: [SavedQuery] {
        let current = activeTab?.session?.id
        return savedQueries.filter { $0.connectionID == nil || $0.connectionID == current }
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
