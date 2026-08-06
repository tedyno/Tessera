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
        // Disconnected connections still browse (and diagram) their last
        // introspected schema straight from the persisted cache.
        console.cachedSchemaProvider = { [weak self] profileID in
            self?.schemaCache[profileID]?.tree
        }

        // Recoloring or renaming a connection must show up in the open tabs'
        // chips and the status bar immediately, not on the next reconnect.
        connections.onProfileChanged = { [weak self] profile in
            guard let self, let session = self.console.session(for: profile.id) else { return }
            session.name = profile.name
            session.colorName = profile.color
            session.location = self.connections.path(forProfile: profile.id)
        }

        // Deleting a connection must take its live session and tabs with it.
        connections.onProfilesRemoved = { [weak self] profileIDs in
            guard let self else { return }
            for profileID in profileIDs {
                self.console.forgetSession(profileID: profileID)
                self.schemaCache[profileID] = nil
            }
            self.persistSchemaCache()
        }
        NotificationCenter.default.addObserver(forName: .mcpSettingsChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMCPServer() }
        }
        startIdleDisconnectSweep()

        // The workspace survives a relaunch: tabs are saved on quit and
        // recreated (without running anything) on the next start.
        restoreOpenTabs()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveOpenTabs() }
        }
        // Keychain housekeeping waits until the app is frontmost: reading the vault
        // prompts on a freshly-signed build, and doing it mid-launch would pop the
        // dialog before the app activates, leaving it stuck in the background.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didPurgeOrphans else { return }
                self.didPurgeOrphans = true
                self.connections.purgeOrphanSecrets()
            }
        }
    }

    /// One-shot guard so the orphan purge runs on the first activation only.
    @ObservationIgnored private var didPurgeOrphans = false

    /// Brings the MCP server in line with the setting: running when enabled, stopped
    /// otherwise. Safe to call repeatedly.
    func syncMCPServer() {
        Task { await applyMCPSetting() }
    }

    private func applyMCPSetting(attempt: Int = 0) async {
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
            // A relaunch can lose the race for the port against its own dying
            // predecessor — retry briefly before giving up until a settings change.
            guard attempt < 5 else { return }
            try? await Task.sleep(for: .seconds(2))
            guard MCPSettings.isEnabled, !mcpRunning else { return }
            await applyMCPSetting(attempt: attempt + 1)
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
    /// `checking` lets a caller vet a different string than the one that runs —
    /// EXPLAIN ANALYZE executes the inner statement, but the safety patterns are
    /// start-anchored and would never match once the prefix is glued on.
    /// A run waiting for its `:name` parameter values (the sheet is up).
    struct PendingParameterRun: Identifiable {
        let id = UUID()
        var sql: String
        var checkSQL: String?
        var names: [String]
        var tab: QueryTab
        /// MySQL escapes `\'` inside strings; Postgres (standard strings) not.
        var backslashEscapes: Bool
    }
    var pendingParameterRun: PendingParameterRun?
    /// Last values by parameter name, pre-filled on the next prompt.
    var lastParameterValues: [String: String] = [:]

    /// Substitutes the collected values and sends the run on its way.
    func runPendingParameters(_ values: [String: String]) {
        guard let pending = pendingParameterRun else { return }
        pendingParameterRun = nil
        lastParameterValues.merge(values) { _, new in new }
        let escapes = pending.backslashEscapes
        let sql = QueryParameters.substitute(pending.sql, values: values,
                                             backslashEscapes: escapes)
        let checkSQL = pending.checkSQL.map {
            QueryParameters.substitute($0, values: values, backslashEscapes: escapes)
        }
        runChecked(sql, checking: checkSQL, on: pending.tab)
    }

    private func runChecked(_ sql: String, checking checkSQL: String? = nil, on tab: QueryTab) {
        // `:name` placeholders pause the run for their values first.
        let backslashEscapes = tab.session?.engine == .mysql
        let parameterNames = QueryParameters.names(in: sql, backslashEscapes: backslashEscapes)
        guard parameterNames.isEmpty else {
            pendingParameterRun = PendingParameterRun(sql: sql, checkSQL: checkSQL,
                                                      names: parameterNames, tab: tab,
                                                      backslashEscapes: backslashEscapes)
            return
        }
        let warnings = SQLSafety.warnings(in: checkSQL ?? sql)
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
        // A cancelled ⇧⌘E leaves no run behind to consume the expectation.
        console.activeTab?.expectedPlan = nil
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
        persistSchemaCache()
    }

    /// Persists the schema cache without ever sharing its value graph across
    /// threads: the encode runs here on the main actor (which exclusively owns the
    /// `CachedSchema` COW buffers), and only the resulting flat `Data` is handed to
    /// a background task for the file write. Sharing the graph via a shallow
    /// `Task.detached` snapshot instead risked a use-after-free — the crash that
    /// surfaced as a corrupt `SchemaColumn` dealloc in `cacheSchema`.
    private func persistSchemaCache() {
        guard let data = schemaCacheStore.encode(schemaCache) else { return }
        let store = schemaCacheStore
        Task.detached { store.write(data) }
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
        guard let tab = console.activeTab, tab.session != nil, !tab.isRunning,
              tab.kind != .diagram else { return false }
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
    // MARK: Tab restoration

    /// Snapshots the open tabs (shape only, no results) for the next launch.
    private func saveOpenTabs() {
        let document = SavedTabsDocument(
            tabs: console.tabs.map { tab in
                let kind: SavedTab.Kind = switch tab.kind {
                case .console: .console
                case .data: .data
                case .diagram: .diagram
                }
                var diagramTable: String?
                if case .table(let table)? = tab.diagram?.scope { diagramTable = table }
                return SavedTab(kind: kind,
                                profileID: tab.session?.id,
                                title: tab.title,
                                sql: tab.sql,
                                dataSchema: tab.dataSchema,
                                dataTable: tab.dataTable,
                                filterWhere: tab.filterWhere,
                                sortOrder: tab.sortOrder.map {
                                    SavedTab.SavedSortKey(column: $0.column, ascending: $0.ascending)
                                },
                                pageLimit: tab.pageLimit,
                                diagramSchema: tab.diagram?.schemaName,
                                diagramTable: diagramTable)
            },
            activeIndex: console.tabs.firstIndex(where: { $0.id == console.activeTabID }),
            layout: encodePane(console.workspace.root))
        SavedTabsStore.save(document)
    }

    /// Serialises the pane tree, referring to tabs by their index in the saved list.
    private func encodePane(_ node: PaneNode) -> SavedPane {
        func indexOf(_ id: UUID) -> Int? { console.tabs.firstIndex { $0.id == id } }
        if let group = node.group {
            return SavedPane(tabs: group.tabIDs.compactMap(indexOf),
                             active: group.activeID.flatMap(indexOf))
        }
        return SavedPane(axis: node.axis?.rawValue,
                         fraction: node.fractions.first,
                         children: node.children.map(encodePane))
    }

    /// Rebuilds a pane node from a saved one, mapping tab indices back to the
    /// freshly restored tabs (`nil` for entries that couldn't be recreated).
    private func decodePane(_ saved: SavedPane, restored: [QueryTab?]) -> PaneNode? {
        func tab(_ index: Int) -> QueryTab? { restored.indices.contains(index) ? restored[index] : nil }
        if let axisRaw = saved.axis, let axis = SplitAxis(rawValue: axisRaw), let children = saved.children {
            let nodes = children.compactMap { decodePane($0, restored: restored) }
            guard nodes.count == 2 else { return nodes.first }   // a dropped child collapses the split
            let fraction = saved.fraction ?? 0.5
            return PaneNode(axis: axis, children: nodes, fractions: [fraction, 1 - fraction])
        }
        let ids = (saved.tabs ?? []).compactMap { tab($0)?.id }
        guard !ids.isEmpty else { return nil }
        let active = saved.active.flatMap { tab($0)?.id } ?? ids.first
        return PaneNode(group: TabGroup(tabIDs: ids, activeID: active))
    }

    /// Recreates the previous launch's tabs. Nothing connects or runs — a
    /// console/data tab loads on its first Run/Refresh, and diagrams render
    /// from the cached schema.
    private func restoreOpenTabs() {
        guard console.tabs.isEmpty, let document = SavedTabsStore.load(),
              !document.tabs.isEmpty else { return }
        // Saved index → restored tab (nil for entries that couldn't be
        // recreated), so a dropped tab can't shift which one gets activated.
        var restored: [QueryTab?] = []
        for saved in document.tabs {
            let session = saved.profileID
                .flatMap { connections.profile(id: $0) }
                .map { ensureSession(profile: $0) }
            switch saved.kind {
            case .diagram:
                guard let session, let schema = saved.diagramSchema else {
                    restored.append(nil)
                    continue
                }
                let scope: DiagramModel.Scope = saved.diagramTable.map { .table($0) } ?? .schema
                // openDiagram is a no-op when the schema is no longer in the cache;
                // only record a tab if one was actually appended, or the positional
                // index map desyncs and a tab ends up in two panes.
                let before = console.tabs.count
                console.openDiagram(schema: schema, scope: scope, on: session)
                restored.append(console.tabs.count > before ? console.tabs.last : nil)
            case .data:
                let tab = QueryTab(title: saved.title, sql: saved.sql)
                tab.session = session
                tab.kind = .data
                tab.dataSchema = saved.dataSchema
                tab.dataTable = saved.dataTable
                tab.filterWhere = saved.filterWhere
                tab.sortOrder = (saved.sortOrder ?? []).map {
                    QueryTab.SortKey(column: $0.column, ascending: $0.ascending)
                }
                tab.pageLimit = QueryTab.clampedPageLimit(saved.pageLimit)
                console.tabs.append(tab)
                restored.append(tab)
            case .console:
                let tab = QueryTab(title: saved.title, sql: saved.sql)
                tab.session = session
                console.tabs.append(tab)
                restored.append(tab)
            }
        }
        // Rebuild the pane layout before activating, so the active tab's pane can
        // take focus. Falls back to a single pane when there's no saved layout.
        if let layout = document.layout, let root = decodePane(layout, restored: restored) {
            console.workspace.root = root
            console.workspace.focusedGroupID = root.allGroups.first?.id
        }
        if let index = document.activeIndex, restored.indices.contains(index),
           let tab = restored[index] {
            console.activate(tab)
        } else if let last = console.tabs.last {
            console.activate(last)
        }
        console.adoptRestoredTabs()
    }

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

    /// Connections offered in a tab's connection picker, each with its organizer
    /// breadcrumb so the picker can rank by proximity.
    var connectionOptions: [ConnectionOption] {
        connections.profiles.map {
            ConnectionOption(id: $0.id, name: $0.name, path: connections.path(forProfile: $0.id))
        }
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

    /// A flat, pre-lowercased searchable entry. The Spotlight index is an array of
    /// these — built once per schema/connection change so each keystroke is a plain
    /// `contains` over the flat list, not a re-walk of every schema tree with a
    /// fresh `.lowercased()` per name.
    private struct SpotlightItem {
        let kind: SpotlightResult.Kind
        let profileID: UUID
        let connectionName: String
        let path: [String]
        let schema: String?
        let table: String?
        let column: String?
        let indexName: String?
        let lowerTitle: String
    }

    @ObservationIgnored private var spotlightIndex: [SpotlightItem] = []
    /// Signature of the inputs the index was built from; when it changes (a schema
    /// is (re)introspected, or a connection is added/renamed/moved) the index is
    /// rebuilt. Stable order (over `profiles`) so an unchanged set hashes equal.
    @ObservationIgnored private var spotlightIndexSignature = -1

    private func spotlightSignature() -> Int {
        var hasher = Hasher()
        for profile in connections.profiles {
            hasher.combine(profile.id)
            hasher.combine(profile.name)
            hasher.combine(connections.path(forProfile: profile.id))
            hasher.combine(schemaCache[profile.id]?.updatedAt)
        }
        return hasher.finalize()
    }

    private func rebuildSpotlightIndex() {
        var items: [SpotlightItem] = []
        for profile in connections.profiles {
            let path = connections.path(forProfile: profile.id)
            items.append(SpotlightItem(kind: .connection, profileID: profile.id,
                                       connectionName: profile.name, path: path,
                                       schema: nil, table: nil, column: nil, indexName: nil,
                                       lowerTitle: profile.name.lowercased()))
            guard let tree = schemaCache[profile.id]?.tree else { continue }
            for namespace in tree.schemas {
                items.append(SpotlightItem(kind: .schema, profileID: profile.id,
                                           connectionName: profile.name, path: path,
                                           schema: namespace.name, table: nil, column: nil,
                                           indexName: nil, lowerTitle: namespace.name.lowercased()))
                for table in namespace.tables {
                    items.append(SpotlightItem(kind: .table, profileID: profile.id,
                                               connectionName: profile.name, path: path,
                                               schema: namespace.name, table: table.name, column: nil,
                                               indexName: nil, lowerTitle: table.name.lowercased()))
                    for column in table.columns {
                        items.append(SpotlightItem(kind: .column, profileID: profile.id,
                                                   connectionName: profile.name, path: path,
                                                   schema: namespace.name, table: table.name,
                                                   column: column.name, indexName: nil,
                                                   lowerTitle: column.name.lowercased()))
                    }
                    for index in table.indexes {
                        items.append(SpotlightItem(kind: .index, profileID: profile.id,
                                                   connectionName: profile.name, path: path,
                                                   schema: namespace.name, table: table.name,
                                                   column: nil, indexName: index.name,
                                                   lowerTitle: index.name.lowercased()))
                    }
                }
            }
        }
        spotlightIndex = items
    }

    func spotlightResults(query: String) -> [SpotlightResult] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        let signature = spotlightSignature()
        if signature != spotlightIndexSignature {
            rebuildSpotlightIndex()
            spotlightIndexSignature = signature
        }
        // Live/cached badge is runtime state (session readiness), so it's resolved
        // per query rather than baked into the index — a handful of profiles.
        let cachedByProfile = Dictionary(uniqueKeysWithValues: connections.profiles.map {
            ($0.id, !(console.session(for: $0.id)?.isReady ?? false))
        })

        var results: [SpotlightResult] = []
        for item in spotlightIndex where item.lowerTitle.contains(needle) {
            results.append(SpotlightResult(kind: item.kind, profileID: item.profileID,
                                           connectionName: item.connectionName, path: item.path,
                                           schema: item.schema, table: item.table, column: item.column,
                                           indexName: item.indexName,
                                           isCached: cachedByProfile[item.profileID] ?? true))
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
        guard let tab = console.activeTab, tab.kind != .diagram else { return }
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

    /// ⌘R: refresh whatever the active tab shows — re-run a console query, reload a
    /// table view, or rebuild a diagram — reconnecting a dropped session first
    /// (`runActiveQuery`/`refreshDiagram` both go through `ensureReady`). Uniform
    /// across tab kinds, and works while disconnected so it can trigger the connect.
    func refreshActiveTab() {
        guard let tab = console.activeTab else { return }
        switch tab.kind {
        case .console, .data:
            runActiveQuery()
        case .diagram:
            tab.task = Task { await console.refreshDiagram(tab) }
        }
    }

    var canRefreshActiveTab: Bool { console.activeTab != nil }

    func runResolved(_ sql: String) {
        guard let tab = console.activeTab else { return }
        pendingRun = nil
        runChecked(sql, on: tab)
    }

    var canExplain: Bool {
        guard let tab = console.activeTab, tab.session != nil, !tab.isRunning,
              tab.kind != .diagram else { return false }
        // Running anything replaces the result and clears pending edits — don't let
        // a reflexive ⌘E eat unsaved changes.
        return !tab.hasEdits
    }

    /// Disabled where the dialect has no separate analyzing form (SQLite's
    /// EXPLAIN QUERY PLAN is its only plan statement).
    var canExplainAnalyze: Bool {
        guard canExplain, let engine = console.activeTab?.session?.engine else { return false }
        let dialect = engine.dialect
        return dialect.explainPrefix(analyze: true).prefix != dialect.explainPrefix(analyze: false).prefix
    }

    /// EXPLAIN (or its analyzing variant) for the statement under the cursor — the
    /// plan lands in the results grid like any query, without touching the editor
    /// text. The analyzing variants actually execute the statement, so they go
    /// through the same destructive-statement confirmation as a normal run.
    func explainActiveQuery(analyze: Bool) {
        guard let tab = console.activeTab, let session = tab.session,
              !tab.isRunning, !tab.hasEdits else { return }
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
        // Prefer the JSON/tree form the plan view can render; engines without
        // one (MySQL's analyze) keep the raw-grid behavior.
        let prefix: String
        let executes: Bool
        if let structured = session.engine.dialect.structuredExplain(analyze: analyze) {
            (prefix, executes) = (structured.prefix, structured.executes)
            tab.expectedPlan = .init(sql: prefix + trimmed, format: structured.format,
                                     analyze: analyze)
        } else {
            (prefix, executes) = session.engine.dialect.explainPrefix(analyze: analyze)
            tab.expectedPlan = nil
        }
        let prefixed = prefix + trimmed
        if executes {
            runChecked(prefixed, checking: trimmed, on: tab)
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

    /// ⌘F — reveals the find bar over the active tab's results grid. A plan
    /// tree has no grid; flip it to the raw view so the bar has somewhere to be.
    func findInResults() {
        guard let tab = console.activeTab else { return }
        if tab.currentPlan != nil { tab.showRawPlan = true }
        let wasVisible = tab.isSearchBarVisible
        tab.isSearchBarVisible = true
        // The sidebar's NSOutlineView keeps first responder until something takes it,
        // and its keyDown swallows plain keystrokes into the connection speed-search.
        // Resign it as the bar opens so the find field (focused on appear) is the only
        // responder left; without this, typing after ⌘F searches the connections list.
        if !wasVisible { NSApp.keyWindow?.makeFirstResponder(nil) }
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
        // Connection name in the base, so `orders` from staging and production
        // don't produce interchangeable files; ad-hoc results are just "query".
        let subject = tab.dataTable ?? "query"
        let base = tab.session.map { "\($0.name)_\(subject)" } ?? subject
        panel.nameFieldStringValue = ExportSettings.fileName(base: base, extension: format.fileExtension)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Qualify the table for generated INSERTs so they can be replayed elsewhere.
        let table = tab.dataSchema.map { "\($0).\(tab.dataTable ?? "")" } ?? tab.dataTable
        // CSV and SQL stream the full result straight to disk — no row cap, nothing
        // held in memory. JSON and XLSX keep the buffered in-memory path.
        let streamFormat: StreamingResultExport.Format?
        switch format {
        case .csv: streamFormat = .csv
        case .sql: streamFormat = .sql
        case .json, .xlsx: streamFormat = nil
        }
        if let streamFormat {
            Task {
                if await console.streamExport(tab, format: streamFormat, table: table, to: url),
                   ExportSettings.revealAfterExport {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            return
        }
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
        guard let profile = connections.profile(id: target.profileID),
              !profile.kind.isFileBased else { return nil }   // a SQLite DB is its own backup
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
        // Drops our reference to the password so it isn't reachable through the
        // model for the rest of the app's run. Not scrubbing — String contents
        // can't be zeroed in place; the Keychain remains the real store.
        duplicatingSecrets = Secrets()
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
