import SwiftUI
import AppKit
import DBKit
import DBMCPServer
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
    @ObservationIgnored private let mcpServer = MCPHTTPServer()
    @ObservationIgnored private lazy var mcpBridge = MCPBridge(app: self)
    var showingMCPLog = false
    private(set) var mcpRunning = false
    private(set) var mcpError: String?

    init() {
        // Let a run auto-reconnect a dropped session before executing.
        console.reconnect = { [weak self] session in
            guard let self, let profile = self.connections.profile(id: session.id) else { return }
            await self.openSession(session, profile: profile)
        }
        NotificationCenter.default.addObserver(forName: .mcpSettingsChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMCPServer() }
        }
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
        return MCPExportResult(path: url.path, bytes: size ?? 0)
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
    /// Cached schema per profile, populated as connections are opened, so search
    /// can span every connection visited this session.
    private var schemaCache: [UUID: DatabaseTree] = [:]

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
    /// if it isn't already live.
    func connect(nodeID: UUID?) {
        guard let nodeID, let profileID = connections.profileID(forNode: nodeID) else { return }
        connectProfile(profileID: profileID)
    }

    func connectProfile(profileID: UUID) {
        guard let profile = connections.profile(id: profileID) else { return }
        let session = ensureSession(profile: profile)
        console.activateTab(for: session)
        guard !session.isReady, !session.isConnecting else { return }
        Task { await openSession(session, profile: profile) }
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

    func reconnect(profileID: UUID) {
        guard let profile = connections.profile(id: profileID) else { return }
        let session = ensureSession(profile: profile)
        Task {
            await session.close()
            await openSession(session, profile: profile)
        }
    }

    func introspect(profileID: UUID) {
        guard let session = console.session(for: profileID) else { return }
        Task {
            await session.refreshSchema()
            if let schema = session.schema { schemaCache[profileID] = schema }
        }
    }

    func isConnected(profileID: UUID) -> Bool { console.session(for: profileID)?.isReady ?? false }
    func isConnecting(profileID: UUID) -> Bool { console.session(for: profileID)?.isConnecting ?? false }

    /// Sidebar status dot for a connection.
    func connectionDot(profileID: UUID) -> ConnectionDot {
        switch console.session(for: profileID)?.status {
        case .ready: .connected
        case .connecting: .connecting
        case .failed: .failed
        case .idle, nil: .none
        }
    }

    /// Changes whenever any session's status changes, so the sidebar dots refresh.
    var sessionStatusVersion: Int {
        var hasher = Hasher()
        for session in console.sessions {
            hasher.combine(session.id)
            hasher.combine(session.status)
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
        if let schema = session.schema { schemaCache[profile.id] = schema }
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
            if profile.name.lowercased().contains(needle) {
                results.append(SpotlightResult(kind: .connection, profileID: profile.id,
                                               connectionName: profile.name, path: path,
                                               schema: nil, table: nil, column: nil))
            }
            guard let tree = schemaCache[profile.id] else { continue }
            for namespace in tree.schemas {
                if namespace.name.lowercased().contains(needle) {
                    results.append(SpotlightResult(kind: .schema, profileID: profile.id,
                                                   connectionName: profile.name, path: path,
                                                   schema: namespace.name, table: nil, column: nil))
                }
                for table in namespace.tables {
                    if table.name.lowercased().contains(needle) {
                        results.append(SpotlightResult(kind: .table, profileID: profile.id,
                                                       connectionName: profile.name, path: path,
                                                       schema: namespace.name, table: table.name, column: nil))
                    }
                    for column in table.columns where column.name.lowercased().contains(needle) {
                        results.append(SpotlightResult(kind: .column, profileID: profile.id,
                                                       connectionName: profile.name, path: path,
                                                       schema: namespace.name, table: table.name, column: column.name))
                    }
                }
            }
        }
        return Array(results.prefix(80))
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
            console.activateTab(for: session)
            if let nodeID = connections.firstNodeID(forProfile: result.profileID) { selection = nodeID }
            if let table = result.table, let schema = result.schema {
                await console.selectAll(schema: schema, table: table)
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
        console.activeTabID = console.tabs[index].id
    }

    func refreshSchema() { Task { await console.refreshSchema() } }
    func showHistory() { showingHistory = true }

    func addRowToActiveTab() {
        guard let tab = console.activeTab else { return }
        console.addInsertRow(tab)
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
        let text = ResultExport.string(from: result, format: format)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
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

    func exportTable(profileID: UUID, schema: String, table: String) {
        exportTarget = ExportTarget(profileID: profileID, schemas: [schema], tables: [table])
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
            tables: target.tables)
    }

    func newConnection() {
        newConnectionParent = connections.organizer.workspaces.first?.id
        showingNewConnection = true
    }

    func editConnection(nodeID: UUID) {
        guard let profileID = connections.profileID(forNode: nodeID),
              let profile = connections.profile(id: profileID) else { return }
        editingProfile = profile
        editingSecrets = connections.secrets(for: profile)
        showingEditConnection = true
    }

    func focusEditor() { editorFocusRequests += 1 }

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
