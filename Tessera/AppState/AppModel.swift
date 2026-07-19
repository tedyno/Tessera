import SwiftUI
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
    var showingNewConnection = false
    var newConnectionParent: UUID?
    var showingHistory = false
    /// Bumped to request first-responder focus in the SQL editor (⌘L).
    var editorFocusRequests = 0

    /// Set when a run needs the user to choose subselect vs. whole statement.
    var pendingRun: RunChoice?
    var showingRunChoice = false

    // MARK: Command targets

    var canRun: Bool { console.status == .ready && !(console.activeTab?.isRunning ?? false) }
    var isRunning: Bool { console.activeTab?.isRunning ?? false }
    var isConnected: Bool { console.status == .ready }

    func connect(nodeID: UUID?) {
        guard let nodeID,
              let profileID = connections.profileID(forNode: nodeID),
              let profile = connections.profile(id: profileID) else { return }
        Task { await console.open(profile: profile, secrets: connections.secrets(for: profile)) }
    }

    func runActiveQuery() {
        guard let tab = console.activeTab else { return }
        if tab.hasEdits {
            tab.task = Task { await console.commitEdits(tab) }
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

    func focusEditor() { editorFocusRequests += 1 }
}
