import SwiftUI
import AppKit
import DBKit
import DBPersistence

/// A connection a tab can be pointed at, for the tab's connection picker. `path` is
/// its organizer breadcrumb (workspace › project › folder…), used to sort the picker
/// by proximity to the tab's current connection and to disambiguate same-named ones.
struct ConnectionOption: Identifiable, Hashable {
    let id: UUID
    let name: String
    let path: [String]
}

/// Column 3 — the detail area. Renders the tiling pane tree (each pane its own tab
/// bar + content) above one shared status bar, plus the app-level sheets. Per-pane
/// UI lives in `PaneView`/`PaneTreeView`; this is the thin shell around them.
struct DetailView: View {
    @Bindable var model: QueryConsoleModel
    /// Exports/dumps/restores, shown in the status bar's task indicator.
    let jobs: BackgroundJobsModel
    @Binding var showingHistory: Bool
    var focusTrigger: Int
    var cursor: Binding<Int>
    var isReadOnly: Bool = false
    var onRun: () -> Void
    /// EXPLAIN (analyze = true executes the statement too) for the current query.
    var onExplain: (Bool) -> Void = { _ in }
    var onExportResult: (ResultExport.Format) -> Void = { _ in }
    /// History actions route to the connection each entry came from.
    var onPickHistory: (QueryHistoryEntry) -> Void = { _ in }
    var onRunHistory: (QueryHistoryEntry) -> Void = { _ in }
    /// Connections a tab can target, and the action to point the active tab at one.
    var connectionOptions: [ConnectionOption] = []
    var onSelectConnection: (UUID) -> Void = { _ in }
    /// Opens the New Connection sheet (empty state on a fresh install).
    var onNewConnection: () -> Void = { }

    /// Owns the tab drag for this window's detail area; handed to every pane
    /// through `PaneEnv`.
    @State private var tabDrag = TabDragState()
    @State private var showingConnectionLog = false
    // Shared with every pane (the data view saves queries too).
    @State private var showingSaveQuery = false
    @State private var saveQueryTitle = ""

    private var env: PaneEnv {
        PaneEnv(isReadOnly: isReadOnly,
                connectionOptions: connectionOptions,
                onSelectConnection: onSelectConnection,
                onRun: onRun,
                onExplain: onExplain,
                onExportResult: onExportResult,
                focusTrigger: focusTrigger,
                onNewConnection: onNewConnection,
                showingHistory: $showingHistory,
                showingSaveQuery: $showingSaveQuery,
                saveQueryTitle: $saveQueryTitle,
                tabDrag: tabDrag)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneTreeView(model: model, node: model.workspace.root, env: env)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            DetailStatusBar(model: model,
                            jobs: jobs,
                            isReadOnly: isReadOnly,
                            showingConnectionLog: $showingConnectionLog,
                            onExportResult: onExportResult)
        }
        // One space for every pane's measurements, so a chip dragged out of one
        // strip can be compared against the others.
        .coordinateSpace(name: TabDragState.space)
        .overlay(alignment: .topLeading) {
            DraggedTabChip(drag: tabDrag, model: model)
        }
        .sheet(isPresented: $showingConnectionLog) {
            ConnectionLogView(log: model.connectionLog)
                .tesseraModalBackground()
        }
        .sheet(item: Binding(get: { model.activeTab?.valueEditor },
                             set: { model.activeTab?.valueEditor = $0 })) { target in
            ValueEditorSheet(target: target) { newValue in
                guard let tab = model.activeTab,
                      tab.resultVersion == target.resultVersion,
                      newValue != (target.isNull ? nil : target.text) else { return }
                tab.captureEditSnapshot()
                tab.setValue(newValue, row: target.row, columnName: target.columnName)
            }
            .tesseraModalBackground()
        }
        // At body level: any pane can save its query.
        .alert("Save Query", isPresented: $showingSaveQuery) {
            TextField("Name", text: $saveQueryTitle)
            Button("Save") {
                if let sql = model.activeTab?.sql { model.saveQuery(title: saveQueryTitle, sql: sql) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this query a name to find it later.")
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(
                history: model.history,
                activeProfileID: model.activeSession?.id,
                activeConnectionName: model.activeSession?.name,
                onPick: { entry in
                    onPickHistory(entry)
                    showingHistory = false
                },
                onRun: { entry in
                    onRunHistory(entry)
                    showingHistory = false
                },
                onClear: { model.clearHistory(profileID: $0) },
                onDelete: { model.deleteHistoryEntries($0) })
                .tesseraModalBackground()
        }
    }
}

/// The chip that follows the cursor during a drag: an ordinary view rather than
/// a system drag image, so it lives exactly as long as the drag does.
///
/// Deliberately its own `View`. The pointer position changes on every mouse
/// move, and read from `DetailView`'s body it would invalidate the whole detail
/// area — pane tree, grid and all — sixty times a second. Here only this
/// overlay redraws.
private struct DraggedTabChip: View {
    let drag: TabDragState
    let model: QueryConsoleModel

    var body: some View {
        if let id = drag.draggedID, let tab = model.tab(id) {
            TabChipBody(tab: tab,
                        // Exactly as it was in the strip, or it lands a few
                        // points off: an active title is a heavier weight.
                        isActive: drag.draggedWasActive,
                        showConnection: model.sessions.count > 1,
                        // Grows back during the settle, ending at the width of
                        // the real chip it is about to be replaced by.
                        showsClose: drag.isSettling)
                .fixedSize()
                // Lifted off the strip while in flight, set back down as it
                // settles: by the time the real chip takes over there is nothing
                // left to fade, so the swap can't be seen.
                .opacity(drag.isSettling ? 1 : 0.92)
                .shadow(color: .black.opacity(drag.isSettling ? 0 : 0.28),
                        radius: drag.isSettling ? 0 : 10,
                        y: drag.isSettling ? 0 : 4)
                .offset(x: drag.location.x - drag.grabOffset.width,
                        y: drag.location.y - drag.grabOffset.height)
                .allowsHitTesting(false)
        }
    }
}
