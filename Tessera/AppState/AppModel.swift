import SwiftUI
import AppKit
import DBKit
import DBMCPServer
import DBPersistence
import UniformTypeIdentifiers

/// Scene-level state so menu-bar commands (keyboard shortcuts) can act on the
/// active window: owns the connections and the query console plus the small bits
/// of UI state the commands toggle.
@MainActor
@Observable
final class AppModel {
    let connections = ConnectionsModel()
    let console = QueryConsoleModel()

    // MARK: MCP

    let mcpApprovals = MCPApprovals()
    let mcpAudit = MCPAuditLog()
    /// Recently deleted connections, so an unattended delete stays undoable.
    let mcpTrash = MCPConnectionTrash()
    @ObservationIgnored private let mcpServer = MCPHTTPServer()
    @ObservationIgnored private lazy var mcpBridge = MCPBridge(app: self)
    var showingMCPLog = false
    private(set) var mcpRunning = false
    private(set) var mcpError: String?
    /// Name/version the connected MCP client reported at `initialize` (Claude Code,
    /// Codex, an editor…). Any client can connect, so this is never assumed.
    var mcpClientName: String?
    /// What to call the client in approval prompts.
    var mcpClientLabel: String { mcpClientName ?? String(localized: "An MCP client") }

    init() {
        // Let a run auto-reconnect a dropped session before executing.
        console.reconnect = { [weak self] session in
            guard let self, let profile = self.connections.profile(id: session.id) else { return }
            await self.openSession(session, profile: profile)
        }
        schemaCache = schemaCacheStore.load()

        // Deleting a connection must take its live session and tabs with it.
        connections.onProfilesRemoved = { [weak self] profileIDs in
            guard let self else { return }
            for profileID in profileIDs {
                self.console.forgetSession(profileID: profileID)
                self.schemaCache[profileID] = nil
            }
            let snapshot = self.schemaCache
            let store = self.schemaCacheStore
            Task.detached { store.save(snapshot) }
        }
        NotificationCenter.default.addObserver(forName: .mcpSettingsChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMCPServer() }
        }
        startIdleDisconnectSweep()
    }

    /// Brings the MCP server in line with the setting: running when enabled, stopped
    /// otherwise. Safe to call repeatedly.
    func syncMCPServer() {
        Task { await applyMCPSetting() }
    }

    private func applyMCPSetting() async {
        guard MCPSettings.isEnabled else {
            await mcpServer.stop()
            mcpRunning = false
            mcpError = nil
            return
        }
        let service = MCPService(source: mcpBridge)
        do {
            try await mcpServer.start(port: MCPSettings.port, token: MCPSettings.token) { data in
                await service.handle(data)
            }
            mcpRunning = true
            mcpError = nil
        } catch {
            mcpRunning = false
            mcpError = "Could not listen on port \(MCPSettings.port): \(error.localizedDescription)"
        }
    }

    /// Connects a profile if needed and returns its live session.
    func ensureSessionReady(profileID: UUID) async -> ConnectionSession? {
        guard let profile = connections.profile(id: profileID) else { return nil }
        let session = ensureSession(profile: profile)
        if !session.isReady { await openSession(session, profile: profile) }
        return session.isReady ? session : nil
    }

    /// Export driven by MCP: destination is ours, never the caller's.
    func runMCPExport(profile: ConnectionProfile, schemas: [String], tables: [String],
                      structure: Bool, data: Bool, gzip: Bool) async throws -> MCPExportResult {
        let target = ExportTarget(profileID: profile.id, schemas: schemas, tables: tables)
        guard let context = exportContext(for: target) else {
            throw MCPToolError("Could not resolve connection details.")
        }
        let serverMajor = context.serverVersion.flatMap(DumpTool.majorVersion)
        guard let binary = await dumpService.locateBest(kind: context.kind, serverMajor: serverMajor,
                                                        override: UserDefaults.standard.string(
                                                            forKey: "tessera.dumpPath.\(context.kind.rawValue)")) else {
            throw MCPToolError("\(DumpTool.binaryName(for: context.kind)) is not installed.")
        }
        let base = tables.first ?? schemas.first ?? context.database
        let url = ExportSettings.directory.appendingPathComponent(
            ExportSettings.fileName(base: base, extension: gzip ? "sql.gz" : "sql"))
        let options = DumpOptions(schemas: schemas, tables: tables,
                                  includeStructure: structure, includeData: data, gzip: gzip)
        let result = await dumpService.dump(kind: context.kind, binaryPath: binary,
                                            host: context.host, port: context.port, user: context.user,
                                            database: context.database, password: context.password,
                                            options: options, outputURL: url)
        guard result.success else { throw MCPToolError(result.message) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return MCPExportResult(path: url.path, bytes: size)
    }

    /// Import driven by MCP, after approval.
    func runMCPImport(profile: ConnectionProfile, filePath: String) async throws -> MCPImportResult {
        guard let context = exportContext(for: ExportTarget(profileID: profile.id)) else {
            throw MCPToolError("Could not resolve connection details.")
        }
        let url = URL(fileURLWithPath: filePath)
        let input = RestoreInput.detect(fileName: url.lastPathComponent)
        let binaryName = RestoreTool.binaryName(for: context.kind, input: input)
        guard let binary = await dumpService.locateBest(
            named: binaryName, engine: context.kind,
            serverMajor: context.serverVersion.flatMap(DumpTool.majorVersion),
            override: UserDefaults.standard.string(
                forKey: "tessera.restorePath.\(context.kind.rawValue).\(binaryName)")) else {
            throw MCPToolError("\(binaryName) is not installed.")
        }
        let result = await dumpService.restore(engine: context.kind, binaryPath: binary,
                                               host: context.host, port: context.port, user: context.user,
                                               database: context.database, password: context.password,
                                               input: input, fileURL: url, options: RestoreOptions())
        guard result.success else { throw MCPToolError(result.message) }
        if let session = console.session(for: profile.id) { await session.refreshSchema() }
        return MCPImportResult(file: filePath, message: "Imported \(url.lastPathComponent)")
    }

    var selection: UUID?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var showingNewConnection = false
    var newConnectionParent: UUID?
    var showingEditConnection = false
    var editingProfile: ConnectionProfile?
    @ObservationIgnored var editingSecrets = Secrets()
    var showingHistory = false
    /// The ⌘K command palette.
    var showingCommandPalette = false
    /// Bumped to request first-responder focus in the SQL editor (⌘L).
    var editorFocusRequests = 0

    /// Set when a run needs the user to choose subselect vs. whole statement.
    var pendingRun: RunChoice?
    var showingRunChoice = false

    /// Confirmation before writing to a read-only connection.
    var showingReadOnlyConfirm = false
    @ObservationIgnored private var pendingCommitTab: QueryTab?

    /// Confirmation before running a destructive statement (DROP / TRUNCATE /
    /// DELETE or UPDATE without WHERE).
    var showingDestructiveConfirm = false
    var destructiveWarnings: [SQLSafety.Warning] = []
    @ObservationIgnored private var pendingDestructiveSQL: String?
    @ObservationIgnored private var pendingScriptTab: QueryTab?

    var destructiveSummary: String {
        destructiveWarnings.map(\.risk.explanation).joined(separator: "\n")
    }

    /// Runs `sql` on the active tab, asking first when it looks destructive.
    private func runChecked(_ sql: String, on tab: QueryTab) {
        let warnings = SQLSafety.warnings(in: sql)
        guard warnings.isEmpty else {
            destructiveWarnings = warnings
            pendingDestructiveSQL = sql
            showingDestructiveConfirm = true
            return
        }
        tab.task = Task { await console.run(tab, sqlToRun: sql) }
    }

    func confirmDestructiveRun() {
        destructiveWarnings = []
        if let scriptTab = pendingScriptTab {
            pendingScriptTab = nil
            scriptTab.task = Task { await console.runScript(scriptTab) }
            return
        }
        guard let sql = pendingDestructiveSQL, let tab = console.activeTab else { return }
        pendingDestructiveSQL = nil
        tab.task = Task { await console.run(tab, sqlToRun: sql) }
    }

    func cancelDestructiveRun() {
        pendingDestructiveSQL = nil
        pendingScriptTab = nil
        destructiveWarnings = []
    }

    var currentIsReadOnly: Bool {
        guard let id = console.currentProfileID, let profile = connections.profile(id: id) else { return false }
        return profile.isReadOnly
    }

    /// Spotlight-style global search (double-Shift).
    var showingSpotlight = false
    /// A schema-tree item to expand/scroll to after a spotlight selection.
    var schemaReveal: SchemaRevealTarget?
    /// Cached schema per profile. Persisted, so search reaches connections that
    /// aren't open — including across launches. Names only, no row data.
    private var schemaCache: [UUID: CachedSchema] = [:]
    @ObservationIgnored private let schemaCacheStore = SchemaCacheStore(
        fileURL: (try? SchemaCacheStore.defaultURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tessera-schema-cache.json"))

    /// Records a freshly introspected schema and writes the cache out.
    private func cacheSchema(_ tree: DatabaseTree, for profileID: UUID) {
        schemaCache[profileID] = CachedSchema(tree: tree, updatedAt: Date())
        let snapshot = schemaCache
        let store = schemaCacheStore
        Task.detached { store.save(snapshot) }
    }

    /// When a connection's cached schema was last read, for the search UI.
    func cachedSchemaDate(for profileID: UUID) -> Date? { schemaCache[profileID]?.updatedAt }

    @ObservationIgnored private var lastShiftTap: TimeInterval = 0
    @ObservationIgnored private var shiftWasDown = false
    @ObservationIgnored private var shiftTapCandidate = false
    @ObservationIgnored private var monitorInstalled = false

    /// Installs the double-Shift local event monitor once. Watches key presses too,
    /// so shift held while typing capitals doesn't count as a tap.
    func installShiftMonitor() {
        guard !monitorInstalled else { return }
        monitorInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if let self {
                MainActor.assumeIsolated {
                    if event.type == .keyDown { self.shiftTapCandidate = false }
                    else { self.flagsChanged(event) }
                }
            }
            return event
        }
    }

    // MARK: Command targets

    // Runnable whenever a tab has a connection and isn't mid-connect/mid-run — a
    // disconnected tab reconnects on run.
    var canRun: Bool {
        guard let tab = console.activeTab, tab.session != nil, !tab.isRunning else { return false }
        return console.status != .connecting
    }
    var isRunning: Bool { console.activeTab?.isRunning ?? false }
    var isConnected: Bool { console.status == .ready }
    var canEditRows: Bool { console.activeTab?.isEditable ?? false }
    var hasPendingChanges: Bool { console.activeTab?.hasEdits ?? false }

    /// Selecting a connection: activate (or create) its session + a tab; connect only
    /// if it isn't already live. Used for an explicit connect action (double-click,
    /// ⌘↩) — never for a plain click, which must stay a side-effect-free selection
    /// so building a multi-selection (⌘/⇧-click, to drag several items into a
    /// folder) doesn't fire off a connection attempt on every row it touches.
    func connect(nodeID: UUID?) {
        guard let nodeID, let profileID = connections.profileID(forNode: nodeID) else { return }
        connectProfile(profileID: profileID)
    }

    /// A plain click on a connection: makes it "current" (so the schema sidebar
    /// follows it) without connecting — safe to call on every click, including ones
    /// that are just extending a multi-selection, since it never touches the network.
    /// Switching to an already-connected session this way still works exactly like
    /// before; only a genuinely new connection attempt is deferred to `connect`.
    func viewConnection(nodeID: UUID?) {
        guard let nodeID, let profileID = connections.profileID(forNode: nodeID),
              let profile = connections.profile(id: profileID) else { return }
        console.selectSession(ensureSession(profile: profile))
    }

    func connectProfile(profileID: UUID) {
        guard let profile = connections.profile(id: profileID) else { return }
        let session = ensureSession(profile: profile)
        // Just make it current: no empty query tab you'd have to close before
        // double-clicking the table you actually wanted.
        console.selectSession(session)
        guard !session.isReady, !session.isConnecting else { return }
        Task { await openSession(session, profile: profile) }
    }

    /// Connections offered in a tab's connection picker.
    var connectionOptions: [ConnectionOption] {
        connections.profiles.map { ConnectionOption(id: $0.id, name: $0.name) }
    }

    /// Points the active tab at a connection (creating a tab if none), connecting it.
    func selectConnection(_ profileID: UUID) {
        guard let profile = connections.profile(id: profileID) else { return }
        let session = ensureSession(profile: profile)
        if console.activeTab == nil { console.addTab() }
        console.activeTab?.session = session
        if !session.isReady, !session.isConnecting {
            Task { await openSession(session, profile: profile) }
        }
    }

    /// The session for a profile, with its name/folder location kept in sync so tabs
    /// can disambiguate same-named connections.
    private func ensureSession(profile: ConnectionProfile) -> ConnectionSession {
        let session = console.ensureSession(profile: profile)
        session.name = profile.name
        session.colorName = profile.color
        session.location = connections.path(forProfile: profile.id)
        return session
    }

    func disconnect(profileID: UUID) {
        guard let session = console.session(for: profileID) else { return }
        Task { await session.close() }
    }

    /// A failed session isn't actually connected to anything — only ready and
    /// in-flight sessions count as something "Disconnect All" can act on.
    var hasActiveConnections: Bool {
        console.sessions.contains { $0.isReady || $0.isConnecting }
    }

    /// Disconnects every live or connecting session (the toolbar "Disconnect All").
    func disconnectAll() {
        for session in console.sessions where session.isReady || session.isConnecting {
            Task { await session.close() }
        }
    }

    /// A session with no query activity for this long auto-disconnects, so a
    /// forgotten tab doesn't keep a database connection open indefinitely.
    private static let idleDisconnectAfter: TimeInterval = 5 * 60
    private static let idleSweepInterval: Duration = .seconds(60)

    /// Runs forever in the background, closing sessions idle past the threshold.
    /// Started once from `init()`.
    private func startIdleDisconnectSweep() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.idleSweepInterval)
                guard let self else { return }
                self.disconnectIdleSessions()
            }
        }
    }

    private func disconnectIdleSessions() {
        let now = Date()
        for session in console.sessions where session.isReady {
            guard now.timeIntervalSince(session.lastActivityAt) >= Self.idleDisconnectAfter else { continue }
            Task { [console] in
                // Re-checked here, immediately before closing, not just above: a query
                // can start in the gap between scheduling this task and it running,
                // and a running query or unsaved edits mean the tab is still very much
                // in use even without a fresh timestamp.
                guard !console.tabs.contains(where: { $0.session === session && ($0.isRunning || $0.hasEdits) })
                else { return }
                await session.close(reason: "Disconnected after 5 minutes idle")
            }
        }
    }

    func reconnect(profileID: UUID) {
        guard let profile = connections.profile(id: profileID) else { return }
        let session = ensureSession(profile: profile)
        Task {
            await session.close()
            await openSession(session, profile: profile)
        }
    }

    /// Switches the connection to another database by reconnecting to it (Postgres
    /// cannot change database on a live connection). The choice sticks across
    /// auto-reconnects via the session's `preferredDatabase`.
    func switchDatabase(profileID: UUID, to database: String) {
        guard let profile = connections.profile(id: profileID) else { return }
        let session = ensureSession(profile: profile)
        guard session.database != database else { return }
        session.preferredDatabase = database
        Task {
            await session.close()
            await openSession(session, profile: profile)
        }
    }

    /// Opens a query tab bound to a connection, connecting it if needed.
    func newQueryTab(profileID: UUID) {
        guard let profile = connections.profile(id: profileID) else { return }
        let session = ensureSession(profile: profile)
        console.selectSession(session)
        console.addTab(boundTo: session)
        if !session.isReady, !session.isConnecting {
            Task { await openSession(session, profile: profile) }
        }
    }

    /// Opens a query tab on whatever connection the schema tree is showing.
    func newQueryTabForCurrentConnection() {
        guard let session = console.activeSession else { return }
        console.addTab(boundTo: session)
    }

    func introspect(profileID: UUID) {
        guard let session = console.session(for: profileID) else { return }
        Task {
            await session.refreshSchema()
            if let schema = session.schema { cacheSchema(schema, for: profileID) }
        }
    }

    func isConnected(profileID: UUID) -> Bool { console.session(for: profileID)?.isReady ?? false }
    func isConnecting(profileID: UUID) -> Bool { console.session(for: profileID)?.isConnecting ?? false }

    /// Sidebar status dot for a connection.
    func connectionDot(profileID: UUID) -> ConnectionDot {
        guard let session = console.session(for: profileID) else { return .none }
        if session.isDisconnecting { return .disconnecting }
        return switch session.status {
        case .ready: .connected
        case .connecting: .connecting
        case .failed: .failed
        case .idle: .none
        }
    }

    /// Changes whenever any session's status changes, so the sidebar dots refresh.
    var sessionStatusVersion: Int {
        var hasher = Hasher()
        for session in console.sessions {
            hasher.combine(session.id)
            hasher.combine(session.status)
            hasher.combine(session.isDisconnecting)
        }
        return hasher.finalize()
    }

    private func openSession(_ session: ConnectionSession, profile: ConnectionProfile) async {
        let secrets: Secrets
        do {
            secrets = try connections.loadSecrets(for: profile)
        } catch {
            session.reportFailure(
                String(localized: "Keychain access was denied. Click Connect again to allow it."))
            return
        }
        await session.open(profile: profile, secrets: secrets)
        if let schema = session.schema { cacheSchema(schema, for: profile.id) }
    }

    // MARK: Spotlight

    /// Handles the double-Shift shortcut from a local event monitor.
    func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let rawShift = flags.contains(.shift)
        let hasOther = !flags.intersection([.command, .option, .control]).isEmpty

        if rawShift, !shiftWasDown {
            shiftTapCandidate = !hasOther // shift went down alone
        }
        if hasOther { shiftTapCandidate = false }
        if !rawShift, shiftWasDown { // shift released
            if shiftTapCandidate {
                if event.timestamp - lastShiftTap < 0.4 {
                    showingSpotlight = true
                    lastShiftTap = 0
                } else {
                    lastShiftTap = event.timestamp
                }
            }
            shiftTapCandidate = false
        }
        shiftWasDown = rawShift
    }

    func spotlightResults(query: String) -> [SpotlightResult] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var results: [SpotlightResult] = []

        for profile in connections.profiles {
            let path = connections.path(forProfile: profile.id)
            // Anything not backed by a live session came from the on-disk cache and
            // may be out of date; the row says so.
            let cached = !(console.session(for: profile.id)?.isReady ?? false)
            if profile.name.lowercased().contains(needle) {
                results.append(SpotlightResult(kind: .connection, profileID: profile.id,
                                               connectionName: profile.name, path: path,
                                               schema: nil, table: nil, column: nil))
            }
            guard let tree = schemaCache[profile.id]?.tree else { continue }
            for namespace in tree.schemas {
                if namespace.name.lowercased().contains(needle) {
                    results.append(SpotlightResult(kind: .schema, profileID: profile.id,
                                                   connectionName: profile.name, path: path,
                                                   schema: namespace.name, table: nil, column: nil,
                                                   isCached: cached))
                }
                for table in namespace.tables {
                    if table.name.lowercased().contains(needle) {
                        results.append(SpotlightResult(kind: .table, profileID: profile.id,
                                                       connectionName: profile.name, path: path,
                                                       schema: namespace.name, table: table.name, column: nil,
                                                   isCached: cached))
                    }
                    for column in table.columns where column.name.lowercased().contains(needle) {
                        results.append(SpotlightResult(kind: .column, profileID: profile.id,
                                                       connectionName: profile.name, path: path,
                                                       schema: namespace.name, table: table.name, column: column.name,
                                                   isCached: cached))
                    }
                    for index in table.indexes where index.name.lowercased().contains(needle) {
                        results.append(SpotlightResult(kind: .index, profileID: profile.id,
                                                       connectionName: profile.name, path: path,
                                                       schema: namespace.name, table: table.name,
                                                       column: nil, indexName: index.name,
                                                       isCached: cached))
                    }
                }
            }
        }
        return Array(Self.ranked(results, needle: needle).prefix(80))
    }

    /// Exact matches first, then names that start with the term, then the rest —
    /// typing a full table name should not bury it under columns that merely
    /// contain it. Ties keep a stable kind order and sort by name.
    private static func ranked(_ results: [SpotlightResult], needle: String) -> [SpotlightResult] {
        func rank(_ title: String) -> Int {
            let name = title.lowercased()
            if name == needle { return 0 }
            if name.hasPrefix(needle) { return 1 }
            return 2
        }
        func kindOrder(_ kind: SpotlightResult.Kind) -> Int {
            switch kind {
            case .connection: 0
            case .schema: 1
            case .table: 2
            case .column: 3
            case .index: 4
            }
        }
        return results.sorted { left, right in
            let (l, r) = (rank(left.title), rank(right.title))
            if l != r { return l < r }
            let (lk, rk) = (kindOrder(left.kind), kindOrder(right.kind))
            if lk != rk { return lk < rk }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    /// Opens the connection for a spotlight result and navigates to its context.
    func open(_ result: SpotlightResult) {
        showingSpotlight = false
        guard let profile = connections.profile(id: result.profileID) else { return }
        Task {
            let session = ensureSession(profile: profile)
            if !session.isReady, !session.isConnecting {
                await openSession(session, profile: profile)
            }
            console.selectSession(session)
            if let nodeID = connections.firstNodeID(forProfile: result.profileID) { selection = nodeID }
            if let table = result.table, let schema = result.schema {
                // Picking a table opens the browsable data view, the same as
                // double-clicking it in the schema tree — not a SELECT in a console tab.
                // Pass the session: a tab from another connection would otherwise win.
                await console.openTable(schema: schema, table: table, on: session)
                if let column = result.column { console.activeTab?.scrollToColumn = column }
                schemaReveal = SchemaRevealTarget(schema: schema, table: table, column: result.column)
            } else if result.kind == .schema, let schema = result.schema {
                schemaReveal = SchemaRevealTarget(schema: schema, table: nil, column: nil)
            }
        }
    }

    func runActiveQuery() {
        guard let tab = console.activeTab else { return }
        if tab.hasEdits {
            if currentIsReadOnly {
                pendingCommitTab = tab
                showingReadOnlyConfirm = true
            } else {
                tab.task = Task { await console.commitEdits(tab) }
            }
            return
        }
        // A data view has no editable SQL; ⌘↩ just refreshes it.
        if tab.kind == .data {
            tab.task = Task { await console.reloadData(tab, refreshCount: true) }
            return
        }
        switch console.resolveRunTarget(tab) {
        case .statement(let sql):
            runChecked(sql.isEmpty ? tab.sql : sql, on: tab)
        case .ambiguous(let choice):
            pendingRun = choice
            showingRunChoice = true
        }
    }

    func runResolved(_ sql: String) {
        guard let tab = console.activeTab else { return }
        pendingRun = nil
        runChecked(sql, on: tab)
    }

    var canExplain: Bool {
        guard let tab = console.activeTab, tab.session != nil, !tab.isRunning else { return false }
        // Running anything replaces the result and clears pending edits — don't let
        // a reflexive ⌘E eat unsaved changes.
        return !tab.hasEdits
    }

    /// EXPLAIN (or EXPLAIN ANALYZE) for the statement under the cursor — the plan
    /// lands in the results grid like any query, without touching the editor text.
    /// ANALYZE actually executes the statement, so it goes through the same
    /// destructive-statement confirmation as a normal run.
    func explainActiveQuery(analyze: Bool) {
        guard let tab = console.activeTab, tab.session != nil, !tab.isRunning, !tab.hasEdits else { return }
        let sql: String
        if tab.kind == .data {
            sql = tab.sql   // the generated SELECT for this data view
        } else {
            switch console.resolveRunTarget(tab) {
            case .statement(let statement): sql = statement.isEmpty ? tab.sql : statement
            case .ambiguous(let choice): sql = choice.statement
            }
        }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prefixed = (analyze ? "EXPLAIN ANALYZE " : "EXPLAIN ") + trimmed
        if analyze {
            runChecked(prefixed, on: tab)
        } else {
            tab.task = Task { await console.run(tab, sqlToRun: prefixed) }
        }
    }

    func confirmReadOnlyCommit() {
        guard let tab = pendingCommitTab else { return }
        pendingCommitTab = nil
        tab.task = Task { await console.commitEdits(tab) }
    }

    func cancelReadOnlyCommit() { pendingCommitTab = nil }

    func stopActiveQuery() {
        guard let tab = console.activeTab else { return }
        Task { await console.cancel(tab) }
    }
    func newTab() { console.addTab() }
    func closeActiveTab() { if let id = console.activeTabID { console.closeTab(id) } }

    func selectTab(_ index: Int) {
        guard console.tabs.indices.contains(index) else { return }
        console.activate(console.tabs[index])
    }

    func refreshSchema() {
        Task {
            await console.refreshSchema()
            if let session = console.activeSession, let schema = session.schema {
                cacheSchema(schema, for: session.id)
            }
        }
    }
    func showHistory() { showingHistory = true }

    /// A tab bound to the connection a history entry came from: reuses the active
    /// console tab if it already targets that connection, otherwise opens a new one
    /// (connecting the session first). Falls back to the active tab when the origin
    /// is unknown (older entry) or the connection was deleted.
    private func historyTab(for entry: QueryHistoryEntry) async -> QueryTab? {
        guard let profileID = entry.profileID, let profile = connections.profile(id: profileID) else {
            if console.activeTab == nil || console.activeTab?.kind != .console { console.addTab() }
            return console.activeTab
        }
        let session = ensureSession(profile: profile)
        if !session.isReady, !session.isConnecting { await openSession(session, profile: profile) }
        if console.activeTab?.session?.id != session.id || console.activeTab?.kind != .console {
            console.addTab()
            console.activeTab?.session = session
        }
        return console.activeTab
    }

    /// Loads a history entry: a table view reopens as a data view, a query loads into
    /// a tab bound to its original connection (without running).
    func loadHistoryEntry(_ entry: QueryHistoryEntry) {
        if entry.isTableView { openHistoryTable(entry); return }
        Task {
            guard let tab = await historyTab(for: entry) else { return }
            tab.sql = entry.sql
        }
    }

    /// Re-runs a history entry against the connection it originally ran on; a table
    /// view reopens as a data view, a query runs in a console tab.
    func runHistoryEntry(_ entry: QueryHistoryEntry) {
        if entry.isTableView { openHistoryTable(entry); return }
        Task {
            guard let tab = await historyTab(for: entry) else { return }
            tab.sql = entry.sql
            runChecked(entry.sql, on: tab)
        }
    }

    /// Reopens a table-view history entry as a data view on its original connection.
    private func openHistoryTable(_ entry: QueryHistoryEntry) {
        guard let schema = entry.schema, let table = entry.table else { return }
        Task {
            if let profileID = entry.profileID, let profile = connections.profile(id: profileID) {
                let session = ensureSession(profile: profile)
                if !session.isReady, !session.isConnecting { await openSession(session, profile: profile) }
                console.selectSession(session)
                await console.openTable(schema: schema, table: table, on: session)
                return
            }
            await console.openTable(schema: schema, table: table)
        }
    }

    func addRowToActiveTab() {
        guard let tab = console.activeTab else { return }
        console.addInsertRow(tab)
    }

    var canFindInResults: Bool { console.activeTab?.result != nil }

    /// ⌘F — reveals the find bar over the active tab's results grid.
    func findInResults() {
        console.activeTab?.isSearchBarVisible = true
    }

    /// Discards all pending edits/inserts/deletes on the active tab.
    func discardPendingChanges() {
        guard let tab = console.activeTab else { return }
        console.discardPending(tab)
    }

    /// Saves the active tab's result as CSV or JSON.
    func exportResult(format: ResultExport.Format) {
        guard let tab = console.activeTab, let result = tab.result else { return }
        let panel = NSSavePanel()
        panel.directoryURL = ExportSettings.directory
        let base = tab.dataTable ?? tab.title
        panel.nameFieldStringValue = ExportSettings.fileName(base: base, extension: format.fileExtension)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Qualify the table for generated INSERTs so they can be replayed elsewhere.
        let table = tab.dataSchema.map { "\($0).\(tab.dataTable ?? "")" } ?? tab.dataTable
        do {
            let data = try ResultExport.data(from: result, format: format, table: table)
            try data.write(to: url, options: .atomic)
            if ExportSettings.revealAfterExport {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            console.activeTab?.errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    var canExportResult: Bool { console.activeTab?.result != nil }

    // MARK: Export (pg_dump / mysqldump)

    let dumpService = DumpService()
    var exportTarget: ExportTarget?
    var importTarget: ImportTarget?

    /// Pending structural change from the schema tree.
    var ddlOperation: DDLOperation?
    var currentEngine: DatabaseKind { console.engine ?? .postgres }

    func startDDL(_ operation: DDLOperation) { ddlOperation = operation }

    func runDDL(_ sql: String) async -> String? { await console.runDDL(sql) }

    func importConnection(profileID: UUID) {
        importTarget = ImportTarget(profileID: profileID)
    }

    /// Import reuses the same resolved connection details as export.
    func importContext(for target: ImportTarget) -> ExportContext? {
        exportContext(for: ExportTarget(profileID: target.profileID))
    }

    /// Whole database — from the connection's Export… or the database node.
    func exportConnection(profileID: UUID) {
        exportTarget = ExportTarget(profileID: profileID)
    }

    func exportSchema(profileID: UUID, schema: String) {
        exportTarget = ExportTarget(profileID: profileID, schemas: [schema])
    }

    /// Dumps several schemas (all in the connection's current database) into one
    /// file — pg_dump takes a --schema flag per schema in a single invocation.
    func exportSchemas(profileID: UUID, schemas: [String]) {
        exportTarget = ExportTarget(profileID: profileID, schemas: schemas)
    }

    func exportTable(profileID: UUID, schema: String, table: String) {
        exportTarget = ExportTarget(profileID: profileID, schemas: [schema], tables: [table])
    }

    /// Dumps several tables (all in the same schema) into one file — pg_dump/mysqldump
    /// both already accept a list of tables in a single invocation.
    func exportTables(profileID: UUID, schema: String, tables: [String]) {
        exportTarget = ExportTarget(profileID: profileID, schemas: [schema], tables: tables)
    }

    /// Everything the export sheet needs, resolved from the live session when possible
    /// (so an SSH-tunnelled connection dumps through the local tunnel endpoint).
    func exportContext(for target: ExportTarget) -> ExportContext? {
        guard let profile = connections.profile(id: target.profileID) else { return nil }
        let session = console.session(for: target.profileID)
        return ExportContext(
            kind: profile.kind,
            connectionName: profile.name,
            host: session?.endpoint?.host ?? profile.host,
            port: session?.endpoint?.port ?? profile.port,
            user: profile.username,
            database: session?.database ?? profile.database,
            password: (try? connections.loadSecrets(for: profile))?.databasePassword,
            serverVersion: session?.serverVersion,
            schemas: target.schemas,
            tables: target.tables,
            tree: session?.schema)
    }

    func newConnection() {
        // No workspace by default: it lands at the loose top level, and the user can
        // drag it into a workspace if they want one.
        newConnectionParent = nil
        showingNewConnection = true
    }

    func editConnection(nodeID: UUID) {
        guard let profileID = connections.profileID(forNode: nodeID),
              let profile = connections.profile(id: profileID) else { return }
        editingProfile = profile
        editingSecrets = connections.secrets(for: profile)
        showingEditConnection = true
    }

    // MARK: Duplicate connection

    var showingDuplicateConnection = false
    var duplicatingProfile: ConnectionProfile?
    @ObservationIgnored var duplicatingSecrets = Secrets()
    /// Where the copy lands: the same container the original sits in.
    @ObservationIgnored private var duplicateParent: UUID?

    /// Opens the connection form prefilled with an existing connection (including
    /// its Keychain secrets). Saving — changed or not — creates a new connection
    /// next to the original.
    func duplicateConnection(nodeID: UUID) {
        guard let profileID = connections.profileID(forNode: nodeID),
              let profile = connections.profile(id: profileID) else { return }
        duplicatingProfile = profile
        duplicatingSecrets = connections.secrets(for: profile)
        duplicateParent = connections.organizer.location(of: nodeID)?.parent
        showingDuplicateConnection = true
    }

    func finishDuplicate(_ profile: ConnectionProfile, secrets: Secrets) {
        // The form carries the original's id (it was seeded from it) — the copy
        // needs its own, or it would share sessions and Keychain entries.
        var copy = profile
        copy.id = UUID()
        let nodeID = connections.addConnection(copy, secrets: secrets, into: duplicateParent)
        duplicateParent = nil
        duplicatingProfile = nil
        selection = nodeID
    }

    func focusEditor() { editorFocusRequests += 1 }

    /// The commands offered by the ⌘K palette (rebuilt each time it opens so the
    /// enabled flags reflect current state). Shortcuts mirror the menu bar.
    func paletteCommands() -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        func add(_ id: String, _ title: String, _ shortcut: String?, _ image: String,
                 enabled: Bool = true, _ action: @escaping () -> Void) {
            commands.append(PaletteCommand(id: id, title: title, shortcut: shortcut,
                                           systemImage: image, enabled: enabled, action: action))
        }
        add("run", String(localized: "Run Query"), "⌘↩", "play.fill", enabled: canRun) { self.runActiveQuery() }
        add("stop", String(localized: "Stop"), "⌘.", "stop.fill", enabled: isRunning) { self.stopActiveQuery() }
        add("new-tab", String(localized: "New Query Tab"), "⌘T", "plus.square") { self.newTab() }
        add("close-tab", String(localized: "Close Tab"), "⌘W", "xmark.square") { self.closeActiveTab() }
        add("new-connection", String(localized: "New Connection…"), "⇧⌘N", "point.3.connected.trianglepath.dotted") { self.newConnection() }
        add("search", String(localized: "Search Everywhere…"), "⇧⌘O", "magnifyingglass") { self.showingSpotlight = true }
        add("toggle-sidebar", String(localized: "Toggle Sidebar"), "⌘S", "sidebar.left") { self.toggleSidebar() }
        add("focus-editor", String(localized: "Focus Editor"), "⌘L", "text.cursor") { self.focusEditor() }
        add("refresh", String(localized: "Refresh Schema"), "⌘R", "arrow.clockwise",
            enabled: isConnected) { self.refreshSchema() }
        add("history", String(localized: "Query History"), "⌘Y", "clock.arrow.circlepath") { self.showHistory() }
        add("open-sql", String(localized: "Open SQL File…"), "⌘O", "doc") { self.openSQLFile() }
        add("run-sql", String(localized: "Run SQL File…"), "⇧⌘R", "doc.badge.gearshape",
            enabled: isConnected) { self.runSQLFile() }
        add("add-row", String(localized: "Add Row"), "⌘N", "plus.rectangle",
            enabled: canEditRows) { self.addRowToActiveTab() }
        add("find-in-results", String(localized: "Find in Results"), "⌘F", "magnifyingglass",
            enabled: canFindInResults) { self.findInResults() }
        add("discard", String(localized: "Discard Pending Changes"), nil, "arrow.uturn.backward",
            enabled: hasPendingChanges) { self.discardPendingChanges() }
        add("export-csv", String(localized: "Export Result as CSV…"), nil, "tablecells",
            enabled: canExportResult) { self.exportResult(format: .csv) }
        add("export-json", String(localized: "Export Result as JSON…"), nil, "curlybraces",
            enabled: canExportResult) { self.exportResult(format: .json) }
        add("mcp", String(localized: "MCP Activity…"), nil, "sparkles") { self.showingMCPLog = true }
        return commands
    }

    /// Loads a `.sql` file into a new console tab (bound to the active connection).
    func openSQLFile() {
        guard let (url, text) = pickSQLFile() else { return }
        loadFileIntoTab(url: url, text: text)
    }

    /// Loads a `.sql` file and runs every statement in it sequentially — asking first
    /// if the script contains destructive statements, exactly as typing them would.
    func runSQLFile() {
        guard let (url, text) = pickSQLFile() else { return }
        guard let tab = loadFileIntoTab(url: url, text: text) else { return }
        let warnings = SQLSafety.warnings(in: text)
        guard warnings.isEmpty else {
            destructiveWarnings = warnings
            pendingScriptTab = tab
            showingDestructiveConfirm = true
            return
        }
        tab.task = Task { await console.runScript(tab) }
    }

    private func pickSQLFile() -> (URL, String)? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText]
        if let sql = UTType(filenameExtension: "sql") { types.insert(sql, at: 0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (url, text)
    }

    @discardableResult
    private func loadFileIntoTab(url: URL, text: String) -> QueryTab? {
        console.addTab()
        guard let tab = console.activeTab else { return nil }
        tab.sql = text
        tab.title = url.lastPathComponent
        return tab
    }

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.16)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    var currentHiddenSchemas: Set<String> {
        guard let id = console.currentProfileID else { return [] }
        return connections.hiddenSchemas(for: id)
    }

    func toggleSchema(_ name: String) {
        guard let id = console.currentProfileID else { return }
        connections.toggleSchema(name, for: id)
    }
}
