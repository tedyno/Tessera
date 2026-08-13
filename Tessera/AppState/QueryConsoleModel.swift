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
        // Cap on load so the in-memory history matches what any later save persists —
        // a legacy file over the per-connection cap trims once, consistently, instead
        // of showing more in memory than survives the next write.
        self.history = historyStore.capped(historyStore.load())

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

    /// Reports the connection that just took focus. `AppModel` moves the organizer
    /// highlight onto it, so the highlighted row and the schema tree can never
    /// disagree — see `focus(_:)`.
    @ObservationIgnored var onFocusSession: ((ConnectionSession) -> Void)?

    /// Makes a connection current without opening anything.
    func selectSession(_ session: ConnectionSession) { focus(session) }

    /// The single place `currentSession` moves, so every path that changes which
    /// connection the schema tree shows also tells the organizer about it.
    private func focus(_ session: ConnectionSession) {
        currentSession = session
        onFocusSession?(session)
    }

    /// Switches to a tab and moves the connection focus with it, so the schema tree
    /// always belongs to what you are looking at. Set explicitly rather than through
    /// a `didSet` on `activeTabID`: property observers inside `@Observable` are a
    /// trap, and every internal caller here needs the focus updated anyway.
    func activate(_ tab: QueryTab) {
        // The value-editor sheet is presented off the *active* tab; leaving it
        // open on a background tab would re-present a stale target on return.
        if activeTabID != tab.id { activeTab?.valueEditor = nil }
        activeTabID = tab.id
        if let session = tab.session { focus(session) }
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
    /// Where a long export reports itself. Set by AppModel.
    @ObservationIgnored var jobs: BackgroundJobsModel?
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
            let tab = QueryTab(title: nextQueryTitle())
            tab.session = session
            tabs.append(tab)
            activate(tab)
        }
    }

    // MARK: Tabs

    /// The next free "Query N" title: the smallest positive N not already used by a
    /// console tab. Only console tabs count (a data/diagram tab must not bump the
    /// number), and freed numbers are reused, so numbering never collides — whether
    /// from closing tabs or duplicating one into a split — nor climbs forever.
    func nextQueryTitle() -> String {
        let prefix = "Query "
        let used = Set(tabs.compactMap { tab -> Int? in
            guard tab.kind == .console, tab.title.hasPrefix(prefix) else { return nil }
            return Int(tab.title.dropFirst(prefix.count))
        })
        var number = 1
        while used.contains(number) { number += 1 }
        return "\(prefix)\(number)"
    }

    /// Opens a console tab. Coming from a table view it starts prefilled with the
    /// query behind that view — handy for tweaking a filter or adding a join — but
    /// deliberately isn't run, so nothing hits the database until you ask.
    func addTab(boundTo session: ConnectionSession? = nil) {
        let tab = QueryTab(title: nextQueryTitle())
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
        // Splitting a pane by its only tab would strand the source empty. Instead
        // fill the new pane with an independent duplicate and leave the original
        // where it is — so a lone tab can still be split into two views.
        if let from = workspace.group(containing: draggedID),
           from.id == targetGroupID, from.tabIDs.count == 1 {
            guard let original = tabs.first(where: { $0.id == draggedID }) else { return }
            let copy = original.duplicated()
            // A console duplicate keeps the SQL but gets its own number, so the
            // split doesn't leave two identically titled tabs. Data/diagram tabs
            // stay named after their table/schema — same name is expected there.
            if copy.kind == .console { copy.title = nextQueryTitle() }
            tabs.append(copy)
            // `copy` is in no group yet, so `splitDropping`'s internal remove is a
            // no-op and the original stays put; the new pane gets the duplicate.
            workspace.splitDropping(tabID: copy.id, targetGroupID: targetGroupID, edge: edge)
            activeTabID = copy.id
            return
        }
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

    /// Which text to run given the caret position — the engine's console
    /// pipeline decides (a `;`-delimited statement for SQL, the current line
    /// for Redis).
    func resolveRunTarget(_ tab: QueryTab) -> SQLRunTarget {
        pipeline(for: tab).runTarget(in: tab.sql, cursor: tab.cursorPosition)
    }

    /// The engine's console strategy (scans, rewrites, run units).
    private func pipeline(for tab: QueryTab) -> any ConsolePipeline {
        (tab.session?.engine ?? .postgres).consolePipeline
    }

    func run(_ tab: QueryTab, sqlToRun: String? = nil, preserveSort: Bool = false,
             preserveSearch: Bool = false) async {
        guard let session = tab.session, !tab.isRunning else { return }
        var sql = sqlToRun ?? tab.sql
        let clock = ContinuousClock()
        let started = clock.now
        if !preserveSort { tab.sortOrder = [] }
        tab.isRunning = true
        tab.errorMessage = nil
        // Reconnect a dropped connection first, then run.
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? String(localized: "Not connected")
            tab.isRunning = false
            return
        }
        // The engine's pre-run rewrite: SQL gets bare string values auto-quoted
        // (`WHERE status = active` → `= 'active'`), Redis runs commands exactly
        // as typed. The editor text stays the user's either way; a data view's
        // SQL is generated from an already-quoted filter and skips this.
        if tab.kind == .console {
            sql = session.engine.consolePipeline.rewriteForRun(
                sql, completion: session.schema != nil ? session.completionEngine : nil)
        }
        do {
            // A data view honors its own "Limit" field — an explicit row count the
            // user asked for is never clipped by the global Max-rows safety cap,
            // which only bounds free-form query results.
            let cap = tab.kind == .data ? tab.pageLimit : ExportSettings.maxRows
            var result = try await driver.execute(sql, maxRows: cap > 0 ? cap : nil)
            // MySQL reads the column list off the first row, so a SELECT matching zero
            // rows comes back with no columns at all — no headers, and `detectEditSource`
            // below would wrongly see it as uneditable. Recover the shape from the
            // introspected schema: a data view knows its table directly; a query tab's
            // `SELECT *` is resolved from its FROM/JOIN tables. (Postgres and SQLite
            // already report columns for empty results, so this only fills the gap.)
            if result.columns.isEmpty, result.rows.isEmpty, result.returnsRows {
                if tab.kind == .data,
                   let schemaName = tab.dataSchema, let tableName = tab.dataTable,
                   let table = session.schema?.schemas.first(where: { $0.name == schemaName })?
                       .tables.first(where: { $0.name == tableName }) {
                    result.columns = table.columns.map { ColumnDescriptor(name: $0.name, typeName: $0.dataType) }
                } else if let columns = RowEditSQL.projectedColumns(sql: sql, schema: session.schema) {
                    result.columns = columns
                }
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
            tab.editSource = RowEditSQL.detectEditSource(sql: sql, columns: result.columns, schema: session.schema)
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
        let statements = session.engine.consolePipeline.scriptStatements(in: tab.sql)
        guard !statements.isEmpty else { return }
        let clock = ContinuousClock()
        let started = clock.now
        tab.isRunning = true
        tab.errorMessage = nil
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? String(localized: "Not connected")
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
                // History is written to disk once after the loop — a long script
                // would otherwise re-encode the whole file per statement.
                recordHistory(sql: statement, session: session,
                              rowCount: lastResult?.rows.count ?? 0, elapsedMS: nil,
                              persist: false)
            }
            tab.result = lastResult ?? QueryResult()
            tab.resultVersion &+= 1
            tab.expectedPlan = nil
            tab.currentPlan = nil
            tab.edits = [:]; tab.pendingDeletes = []; tab.pendingInserts = []
            tab.clearEditHistory()
            tab.clearSearch()
            tab.editSource = nil   // a script isn't a single editable table view
            tab.scriptSummary = String(localized: "Executed \(executed) statements")
        } catch {
            tab.scriptSummary = nil
            tab.errorMessage = String(localized: "Statement \(executed + 1) of \(statements.count) failed:") + "\n"
                + ConnectionSession.message(for: error)
        }
        if executed > 0 { persistHistory() }
        tab.isRunning = false
        Self.bounceDockIfLong(started, clock: clock)
    }

    /// Writes pending edits/deletes/inserts, then re-runs the query to show saved data.
    func commitEdits(_ tab: QueryTab) async {
        guard let session = tab.session, tab.editSource != nil, tab.hasEdits else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        guard await ensureReady(session), let driver = session.driver else {
            tab.errorMessage = session.errorMessage ?? String(localized: "Not connected")
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
        let newSQL = DataViewSQL.rewriteOrderBy(
            tab.sql, sortOrder: tab.sortOrder.map { .init(column: $0.column, ascending: $0.ascending) },
            dialect: session.engine.dialect)
        tab.sql = newSQL
        await run(tab, sqlToRun: newSQL, preserveSort: true)
    }

    /// The UPDATE/DELETE/INSERT statements ⌘↩ would run for the tab's pending changes.
    /// Rows with identical edits collapse into a single `… WHERE pk IN (…)`; deletes
    /// likewise. Without a primary key the WHERE matches all selected columns.
    func pendingStatements(_ tab: QueryTab) -> [String] {
        guard let session = tab.session, let source = tab.editSource, let result = tab.result else { return [] }
        return RowEditSQL.statements(source: source, result: result, edits: tab.edits,
                                     deletes: tab.pendingDeletes,
                                     inserts: tab.pendingInserts.map(\.values),
                                     dialect: session.engine.dialect)
    }

    /// The panel's entries — the exact statements ⌘↩ will run, grouped the
    /// same way `pendingStatements` groups them (identical change-sets share
    /// one `WHERE pk IN (…)` UPDATE); discarding a group reverts all its rows.
    func pendingChanges(_ tab: QueryTab) -> [PendingChange] {
        guard let session = tab.session, let source = tab.editSource, let result = tab.result else { return [] }
        let dialect = session.engine.dialect
        let table = RowEditSQL.qualifiedTable(source, dialect: dialect)
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
                   clauses: RowEditSQL.whereClauses(rows: deleteRows, keyColumns: keyColumns,
                                                    result: result, dialect: dialect),
                   id: { "d\($0)" }, target: { .delete(rows: $0) },
                   statement: { "DELETE FROM \(table) WHERE \($0);" })
        }
        for group in RowEditSQL.editGroups(tab.edits, skipping: tab.pendingDeletes) {
            let setClause = RowEditSQL.updateSetClause(group.changes, result: result, dialect: dialect)
            append(rows: group.rows,
                   clauses: RowEditSQL.whereClauses(rows: group.rows, keyColumns: keyColumns,
                                                    result: result, dialect: dialect),
                   id: { "u\($0)" }, target: { .update(rows: $0) },
                   statement: { "UPDATE \(table) SET \(setClause) WHERE \($0);" })
        }
        for insert in tab.pendingInserts {
            let statement = RowEditSQL.insertStatement(table: table, values: insert.values,
                                                       source: source, result: result, dialect: dialect)
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

    // MARK: Data views (schema-tree table browsing)

    /// Opens a dedicated data-view tab (grid + filter + paging, no SQL editor) for a
    /// table on the active connection. Double-clicking a table in the schema tree.
    /// `on` names the connection explicitly. Without it the active *tab* decides,
    /// which is wrong when opening a search hit that belongs to another connection.
    func openTable(schema: String, table: String, on session: ConnectionSession? = nil) async {
        guard let session = session ?? activeSession else { return }
        let (tab, isNew) = dataTab(schema: schema, table: table, on: session)
        // A restored (or idle-disconnected) tab is focused but has no live
        // connection and no data — clicking it in the schema should behave like
        // opening it fresh: reconnect and load. A tab already showing data on a
        // live connection just refocuses, keeping its scroll and any edits.
        if isNew || !session.isReady || tab.result == nil {
            await reloadData(tab, refreshCount: true)
        }
    }

    /// Opens the table on the other end of a foreign key, filtered to the rows the
    /// reference selects — "follow this reference", in either direction. Reuses an
    /// existing view of that table, replacing its filter so the same tab doesn't
    /// keep a stale one.
    func openReferencedTable(schema: String, table: String, where clause: String) async {
        // Stays on the tab's own connection — a foreign key never crosses databases.
        guard let session = activeSession else { return }
        let (tab, _) = dataTab(schema: schema, table: table, on: session)
        // The filter is in place before the first load, so the tab never flashes
        // the unfiltered table on its way to the referenced rows.
        tab.filterWhere = clause
        tab.sortOrder = []
        tab.pageLimit = QueryTab.defaultPageLimit
        await reloadData(tab, refreshCount: true)
    }

    /// Focuses the data-view tab for a table on this connection, creating (but not
    /// loading) one when none exists yet — the caller decides how to load it.
    private func dataTab(schema: String, table: String,
                         on session: ConnectionSession) -> (tab: QueryTab, isNew: Bool) {
        // Reuse an existing data view for the same table on this connection.
        if let existing = tabs.first(where: {
            $0.session === session && $0.kind == .data && $0.dataSchema == schema && $0.dataTable == table
        }) {
            activate(existing)
            return (existing, false)
        }
        let tab = QueryTab(title: table)
        tab.session = session
        tab.kind = .data
        tab.dataSchema = schema
        tab.dataTable = table
        tab.pageLimit = QueryTab.defaultPageLimit
        tabs.append(tab)
        activate(tab)
        return (tab, true)
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
        return DataViewSQL.select(
            schema: schema, table: table, filter: tab.filterWhere,
            sortOrder: tab.sortOrder.map { .init(column: $0.column, ascending: $0.ascending) },
            limit: limit ?? tab.pageLimit, offset: offset, orderOverride: orderOverride,
            unlimited: unlimited, dialect: session.engine.dialect)
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
            tab.errorMessage = session.errorMessage ?? String(localized: "Not connected")
            return false
        }
        let job = jobs?.start(title: String(localized: "Exporting \(url.lastPathComponent)"),
                              fileURL: url,
                              onCancel: { [weak tab] in tab?.exportTask?.cancel() })
        // Only a data view knows how many rows are coming, and only then can the bar
        // be a fraction rather than a spinner.
        let expectedRows = tab.kind == .data ? tab.totalRows : nil
        let gate = ProgressGate()
        do {
            _ = try await StreamingResultExport.export(
                exportSQL(tab), from: driver, format: format,
                table: table ?? "table", to: url,
                onProgress: { [weak self] summary in
                    // The driver streams off the main actor; the model is main-actor state.
                    Task { @MainActor in
                        guard let self, let job, gate.allow() else { return }
                        self.jobs?.update(job, detail: Self.exportDetail(summary),
                                          progress: expectedRows.map {
                                              $0 > 0 ? Double(summary.rows) / Double($0) : 1
                                          })
                    }
                },
                // Polled inside the exporting task, so Stop cancelling that task is
                // what this reads.
                shouldCancel: { Task.isCancelled })
            if let job { jobs?.finish(job, state: .succeeded) }
            return true
        } catch is CancellationError {
            // The user pressed Stop; the destination file was left untouched, so this
            // is an outcome, not an error.
            if let job { jobs?.finish(job, state: .cancelled) }
            return false
        } catch {
            let message = ConnectionSession.message(for: error)
            if let job { jobs?.finish(job, state: .failed(message)) }
            tab.errorMessage = String(localized:
                "Could not write \(url.lastPathComponent): \(message)")
            return false
        }
    }

    /// "1 240 000 rows · 84 MB" — the line under an export's title.
    static func exportDetail(_ summary: StreamingResultExport.Summary) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file)
        return String(localized: "^[\(summary.rows) row](inflect: true) · \(bytes)")
    }

    /// Lets progress through about ten times a second. Batches land every few
    /// milliseconds on a fast table, and redrawing the status bar per batch is both
    /// wasted work and unreadable.
    @MainActor
    final class ProgressGate {
        private var last = Date.distantPast
        private let interval: TimeInterval

        init(interval: TimeInterval = 0.1) { self.interval = interval }

        func allow() -> Bool {
            let now = Date()
            guard now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
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

    // MARK: Redis key browser

    static let redisScanPageSize = 500

    /// Opens (or refocuses) the key browser for a Redis session and loads the
    /// first page.
    func openRedisKeys(on session: ConnectionSession? = nil) async {
        guard let session = session ?? activeSession, session.engine.isKeyValue else { return }
        if let existing = tabs.first(where: { $0.session === session && $0.kind == .redisKeys }) {
            activate(existing)
            if existing.result == nil { await reloadRedisKeys(existing) }
            return
        }
        let tab = QueryTab(title: String(localized: "Keys"))
        tab.session = session
        tab.kind = .redisKeys
        tabs.append(tab)
        activate(tab)
        await reloadRedisKeys(tab)
    }

    /// Restarts the scan with the tab's current pattern.
    func reloadRedisKeys(_ tab: QueryTab) async {
        guard tab.kind == .redisKeys, let session = tab.session, !tab.isRunning else { return }
        tab.isRunning = true
        tab.errorMessage = nil
        defer { tab.isRunning = false }
        guard await ensureReady(session), let driver = session.driver as? KeyValueDriver else {
            tab.errorMessage = session.errorMessage ?? String(localized: "Not connected")
            return
        }
        do {
            tab.redisActivePattern = tab.redisPattern
            let page = try await driver.scanPage(matching: tab.redisActivePattern, cursor: "0",
                                                 target: Self.redisScanPageSize)
            tab.redisCursor = page.cursor
            tab.result = RedisGridDisplay.keyListResult(page.keys, truncated: page.cursor != "0")
            tab.hasMoreRows = page.cursor != "0"
            tab.resultVersion &+= 1
            tab.totalRows = await databaseSize(session)
        } catch {
            tab.errorMessage = ConnectionSession.message(for: error)
        }
    }

    /// Fetches and appends the next SCAN page.
    func loadMoreRedisKeys(_ tab: QueryTab) async {
        guard tab.kind == .redisKeys, tab.redisCursor != "0", !tab.isRunning,
              let session = tab.session,
              let driver = session.driver as? KeyValueDriver else { return }
        tab.isRunning = true
        defer { tab.isRunning = false }
        do {
            let page = try await driver.scanPage(matching: tab.redisActivePattern,
                                                 cursor: tab.redisCursor,
                                                 target: Self.redisScanPageSize)
            tab.redisCursor = page.cursor
            let appended = RedisGridDisplay.keyListResult(page.keys, truncated: false)
            tab.result?.rows += appended.rows
            tab.result?.isTruncated = page.cursor != "0"
            tab.hasMoreRows = page.cursor != "0"
            tab.resultVersion &+= 1
        } catch {
            tab.errorMessage = ConnectionSession.message(for: error)
        }
    }

    /// Opens a key in a console tab preloaded with the type-appropriate read
    /// command (GET/HGETALL/LRANGE/…) and runs it.
    func openRedisKey(_ key: String, type: String, on session: ConnectionSession? = nil) async {
        guard let session = session ?? activeSession else { return }
        let command = RedisCommandLine.readCommand(key: key, type: type)
        if let existing = tabs.first(where: {
            $0.session === session && $0.kind == .console && $0.title == key
        }) {
            activate(existing)
            existing.sql = command
        } else {
            let tab = QueryTab(title: key)
            tab.session = session
            tab.kind = .console
            tab.sql = command
            tabs.append(tab)
            activate(tab)
        }
        if let tab = activeTab { await run(tab, sqlToRun: command) }
    }

    /// Deletes keys on the server after an explicit confirmation, then reloads
    /// the browser page. Redis DEL is immediate — there is no pending-edit stage
    /// to revert, so the dialog is the only safety net.
    func deleteRedisKeys(_ keys: [String], in tab: QueryTab) async {
        guard tab.kind == .redisKeys, !keys.isEmpty,
              let driver = tab.session?.driver as? KeyValueDriver else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = keys.count == 1
            ? String(localized: "Delete the key “\(keys[0])”?")
            : String(localized: "Delete \(keys.count) keys?")
        alert.informativeText = String(localized: "DEL runs on the server immediately — there is no undo.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try await driver.deleteKeys(keys)
            await reloadRedisKeys(tab)
        } catch {
            tab.errorMessage = ConnectionSession.message(for: error)
        }
    }

    /// DBSIZE of the session's current database, for the "N of TOTAL" status.
    private func databaseSize(_ session: ConnectionSession) async -> Int? {
        guard let driver = session.driver else { return nil }
        guard let result = try? await driver.execute("DBSIZE", maxRows: 1),
              let text = result.rows.first?.first?.text else { return nil }
        return Int(text)
    }

    /// Fetches `SELECT count(*)` for the current filter so the UI can show "N of TOTAL".
    private func refreshCount(_ tab: QueryTab) async {
        guard let session = tab.session, let driver = session.driver,
              let schema = tab.dataSchema, let table = tab.dataTable else { return }
        session.touch()
        let sql = DataViewSQL.count(schema: schema, table: table, filter: tab.filterWhere,
                                    dialect: session.engine.dialect)
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
        if tab.kind == .redisKeys { return await loadMoreRedisKeys(tab) }
        guard tab.kind == .data, !tab.hasEdits, !tab.isRunning,
              let session = tab.session, tab.result != nil else { return }
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
            tab.errorMessage = session.errorMessage ?? String(localized: "Not connected")
            return
        }
        let offset = tab.result?.rows.count ?? 0
        let sql = dataSQL(tab, limit: QueryTab.pageSize, offset: offset, orderOverride: ordering)
        do {
            let page = try await driver.execute(sql, maxRows: QueryTab.pageSize)
            guard !page.rows.isEmpty else { tab.hasMoreRows = false; return }
            // Append in place: `tab.result` is the sole owner of its row buffer here,
            // so this extends it rather than copying the whole accumulated result
            // every page (which grew to O(N²) over a long infinite scroll).
            tab.result?.rows.append(contentsOf: page.rows)
            tab.result?.isTruncated = page.isTruncated
            tab.hasMoreRows = page.isTruncated   // a full page means more may follow
            tab.resultVersion &+= 1
            tab.pageLimit = tab.result?.rows.count ?? tab.pageLimit
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
            tab.sql = DataViewSQL.rewriteOrderBy(tab.sql, sortOrder: [], dialect: session.engine.dialect)
            await run(tab, sqlToRun: tab.sql, preserveSort: true)
        }
    }

    /// Applies a new WHERE filter, resets paging, and refreshes the count.
    /// No-op with pending changes so a reload can't silently discard them.
    /// Bare string values are auto-quoted (`status = active` → `= 'active'`) and
    /// the fixed clause is written back so the field shows what actually runs.
    func applyFilter(_ tab: QueryTab, where clause: String) async {
        guard tab.kind == .data, !tab.hasEdits else { return }
        tab.filterWhere = autoQuotedFilter(clause, tab: tab)
        tab.pageLimit = QueryTab.defaultPageLimit
        await reloadData(tab, refreshCount: true)
    }

    private func autoQuotedFilter(_ clause: String, tab: QueryTab) -> String {
        guard let schemaName = tab.dataSchema, let tableName = tab.dataTable,
              let table = schema(for: tab)?.schemas.first(where: { $0.name == schemaName })?
                  .tables.first(where: { $0.name == tableName }) else { return clause }
        return SQLAutoQuote.quoted(clause, scope: SQLAutoQuote.Scope(table: table))
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

    /// ⌘R on a diagram tab: reconnect a dropped session, re-introspect the schema,
    /// and rebuild the diagram from the fresh snapshot (positions re-layout, like
    /// reopening it). Mirrors how a query/table view refreshes.
    func refreshDiagram(_ tab: QueryTab) async {
        guard tab.kind == .diagram, let session = tab.session,
              let diagram = tab.diagram else { return }
        tab.isRunning = true
        defer { tab.isRunning = false }
        guard await ensureReady(session) else {
            tab.errorMessage = session.errorMessage ?? String(localized: "Not connected")
            return
        }
        await session.refreshSchema()
        guard let namespace = session.schema?.schemas.first(where: { $0.name == diagram.schemaName })
        else { return }
        tab.diagram = DiagramModel(schemaName: diagram.schemaName, namespace: namespace, scope: diagram.scope)
        focus(tab.diagram)
    }

    // MARK: History

    /// Applies a schema change on the active connection and re-introspects, so the
    /// tree reflects it right away. Returns an error message on failure.
    /// Runs a schema change. `affecting` names the table it changes, whose open data
    /// views are reloaded afterwards — without that, a TRUNCATE leaves every grid on
    /// that table showing rows that no longer exist.
    func runDDL(_ sql: String, affecting table: (schema: String?, name: String)? = nil) async -> String? {
        guard let session = activeSession else { return String(localized: "Not connected") }
        guard await ensureReady(session), let driver = session.driver else {
            return session.errorMessage ?? String(localized: "Not connected")
        }
        do {
            _ = try await driver.execute(sql)
            recordHistory(sql: sql, session: session, rowCount: 0, elapsedMS: nil)
            await session.refreshSchema()
            if let table {
                await reloadDataViews(schema: table.schema, table: table.name, on: session)
            }
            return nil
        } catch {
            return ConnectionSession.message(for: error)
        }
    }

    /// Re-runs every open data view of one table on one connection. Tabs with unsaved
    /// edits are left alone, the same rule auto-refresh follows: the rows behind those
    /// edits may be gone, but discarding what the user typed without asking is worse
    /// than a grid they can refresh themselves.
    private func reloadDataViews(schema: String?, table: String,
                                 on session: ConnectionSession) async {
        let affected = tabs.filter {
            $0.kind == .data && $0.session === session && $0.dataTable == table
                && (schema == nil || $0.dataSchema == nil || $0.dataSchema == schema)
                && !$0.hasEdits && !$0.isRunning
        }
        for tab in affected {
            await reloadData(tab, refreshCount: true)
        }
    }

    /// Stops a running query: cancels the client task *and* asks the server to abort
    /// it, so a heavy query doesn't keep burning resources after Stop.
    func cancel(_ tab: QueryTab) async {
        tab.task?.cancel()
        await tab.session?.driver?.cancelRunningQuery()
    }

    /// Empties the query history (and its on-disk store) — one connection's when a
    /// profile is given, otherwise all of it.
    /// Removes individual history entries (the history sheet's Delete).
    func deleteHistoryEntries(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let doomed = Set(ids)
        history.removeAll { doomed.contains($0.id) }
        persistHistory()
    }

    func clearHistory(profileID: UUID? = nil) {
        history = profileID.map { QueryHistoryStore.removing(history, profileID: $0) } ?? []
        persistHistory()
    }

    /// Drops the history of several deleted connections in one pass, persisting only
    /// once — used when a batch of profiles is removed together.
    func clearHistory(profileIDs: [UUID]) {
        let ids = Set(profileIDs)
        guard !ids.isEmpty else { return }
        let before = history.count
        history.removeAll { $0.profileID.map(ids.contains) ?? false }
        guard history.count != before else { return }
        persistHistory()
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

    /// Persists saved queries without sharing their value graph across threads: the
    /// encode runs here on the main actor (sole owner of the COW buffers) and only
    /// the flat `Data` is handed to a background writer, which serializes and
    /// coalesces so a burst of saves can't land an older snapshot last.
    private func persistSavedQueries() {
        guard let data = savedQueryStore.encode(savedQueries) else { return }
        savedQueryWriter.submit(data)
    }

    /// Persists history the same copy-isolated way as `persistSavedQueries`.
    private func persistHistory() {
        guard let data = historyStore.encode(history) else { return }
        historyWriter.submit(data)
    }

    @ObservationIgnored private lazy var savedQueryWriter =
        SnapshotWriter { [savedQueryStore] in savedQueryStore.write($0) }
    @ObservationIgnored private lazy var historyWriter =
        SnapshotWriter { [historyStore] in historyStore.write($0) }

    /// `persist: false` lets a caller batch many entries (a script run) and write
    /// the history file once afterwards instead of re-encoding it per statement.
    private func recordHistory(sql: String, session: ConnectionSession, rowCount: Int, elapsedMS: Int?,
                               persist: Bool = true,
                               schema: String? = nil, table: String? = nil) {
        // Collapse a re-run of the identical query on the same connection (e.g.
        // refreshing a table view) into the existing entry instead of duplicating it.
        // The match is per connection, so alternating between two databases still
        // collapses rather than piling up duplicates.
        if let i = QueryHistoryStore.newestIndex(in: history, profileID: session.id,
                                                 sql: sql, table: table) {
            history[i].timestamp = Date()
            history[i].rowCount = rowCount
            history[i].elapsedMS = elapsedMS
            if i != 0 { history.insert(history.remove(at: i), at: 0) }   // back to newest
        } else {
            let entry = QueryHistoryEntry(
                sql: sql, connectionName: session.name, profileID: session.id,
                schema: schema, table: table, timestamp: Date(),
                rowCount: rowCount, elapsedMS: elapsedMS)
            history.insert(entry, at: 0)
            history = historyStore.capped(history)
        }
        // Persist off the main actor so a query never blocks the UI on disk I/O.
        if persist { persistHistory() }
    }

    // MARK: Helpers

    private static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
