import SwiftUI
import AppKit
import DBKit

/// Scene-level state so menu-bar commands (keyboard shortcuts) can act on the
/// active window: owns the connections and the query console plus the small bits
/// of UI state the commands toggle.
@MainActor
@Observable
final class AppModel {
    let connections = ConnectionsModel()
    let console = QueryConsoleModel()

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

    var canRun: Bool { console.status == .ready && !(console.activeTab?.isRunning ?? false) }
    var isRunning: Bool { console.activeTab?.isRunning ?? false }
    var isConnected: Bool { console.status == .ready }

    func connect(nodeID: UUID?) {
        guard let nodeID,
              let profileID = connections.profileID(forNode: nodeID),
              let profile = connections.profile(id: profileID) else { return }
        guard profileID != console.currentProfileID else { return }
        Task {
            await console.open(profile: profile, secrets: connections.secrets(for: profile))
            if let schema = console.schema { schemaCache[profileID] = schema }
        }
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
            // Open first; only then update `selection` — by then currentProfileID
            // matches, so the selection `onChange` won't kick off a second open.
            if console.currentProfileID != profile.id {
                await console.open(profile: profile, secrets: connections.secrets(for: profile))
                if let schema = console.schema { schemaCache[profile.id] = schema }
            }
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
        switch console.resolveRunTarget(tab) {
        case .statement(let sql):
            let target = sql.isEmpty ? tab.sql : sql
            tab.task = Task { await console.run(tab, sqlToRun: target) }
        case .ambiguous(let choice):
            pendingRun = choice
            showingRunChoice = true
        }
    }

    func runResolved(_ sql: String) {
        guard let tab = console.activeTab else { return }
        pendingRun = nil
        tab.task = Task { await console.run(tab, sqlToRun: sql) }
    }

    func confirmReadOnlyCommit() {
        guard let tab = pendingCommitTab else { return }
        pendingCommitTab = nil
        tab.task = Task { await console.commitEdits(tab) }
    }

    func cancelReadOnlyCommit() { pendingCommitTab = nil }

    func stopActiveQuery() { console.activeTab?.task?.cancel() }
    func newTab() { console.addTab() }
    func closeActiveTab() { if let id = console.activeTabID { console.closeTab(id) } }

    func selectTab(_ index: Int) {
        guard console.tabs.indices.contains(index) else { return }
        console.activeTabID = console.tabs[index].id
    }

    func refreshSchema() { Task { await console.refreshSchema() } }
    func showHistory() { showingHistory = true }

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
