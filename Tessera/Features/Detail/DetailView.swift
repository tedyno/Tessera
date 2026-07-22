import SwiftUI
import AppKit
import DBKit
import DBPersistence

/// A connection a tab can be pointed at, for the tab's connection picker.
struct ConnectionOption: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// Column 3 — detail with query tabs, a live SQL editor, Run, the results table,
/// and query history. Each tab has its own editor and result but shares the
/// connection.
///
/// A thin orchestrator: the tab bar, toolbars, results area, inspector,
/// pending-changes panel and status bar each live in their own file
/// (`DetailTabBar`, `DetailView+Toolbars`, `DetailResultsArea`,
/// `ValueInspectorPanel`, `PendingChangesPanel`, `DetailStatusBar`).
struct DetailView: View {
    @Bindable var model: QueryConsoleModel
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

    /// Whether the value inspector panel is shown below the results grid.
    @State private var showInspector = false
    @State private var showingConnectionLog = false
    // Shared with the toolbars extension (the data view saves queries too).
    @State var showingSaveQuery = false
    @State var saveQueryTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            DetailTabBar(model: model)
            Divider()
            if model.activeTab == nil {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let tab = model.activeTab, tab.kind == .diagram, let diagram = tab.diagram {
                DiagramTabView(model: diagram,
                               onOpenTable: { schema, table in
                                   Task { await model.openTable(schema: schema, table: table, on: tab.session) }
                               },
                               onShowWholeSchema: {
                                   model.openDiagram(schema: diagram.schemaName, on: tab.session)
                               })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let tab = model.activeTab, tab.kind == .data {
                    dataToolbar(tab)
                    Divider()
                    dataSQLView(tab)
                } else {
                    editorToolbar
                    Divider()
                    editor
                }
                Divider()
                DetailResultsArea(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector, let tab = model.activeTab, tab.result != nil {
                    Divider()
                    ValueInspectorPanel(tab: tab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let tab = model.activeTab, tab.hasEdits {
                    Divider()
                    PendingChangesPanel(model: model, tab: tab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            DetailStatusBar(model: model,
                            isReadOnly: isReadOnly,
                            showInspector: $showInspector,
                            showingConnectionLog: $showingConnectionLog,
                            onExportResult: onExportResult)
        }
        // The bottom panels slide in rather than snapping the layout around.
        .animation(.snappy(duration: 0.25), value: showInspector)
        .animation(.snappy(duration: 0.25), value: model.activeTab?.hasEdits ?? false)
        .sheet(isPresented: $showingConnectionLog) {
            ConnectionLogView(log: model.connectionLog)
                .tesseraModalBackground()
        }
        .sheet(item: Binding(get: { model.activeTab?.valueEditor },
                             set: { model.activeTab?.valueEditor = $0 })) { target in
            ValueEditorSheet(target: target) { newValue in
                guard let tab = model.activeTab,
                      // The result was replaced while the sheet was up (a run
                      // finishing late) — the captured row would hit the wrong
                      // record now, so the save is dropped rather than misapplied.
                      tab.resultVersion == target.resultVersion,
                      // No change, no snapshot: a no-op save would still clear
                      // the redo stack.
                      newValue != (target.isNull ? nil : target.text) else { return }
                tab.captureEditSnapshot()
                tab.setValue(newValue, row: target.row, columnName: target.columnName)
            }
            .tesseraModalBackground()
        }
        // At body level, not on the editor toolbar: the data view saves queries too.
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
                onPick: { entry in
                    onPickHistory(entry)
                    showingHistory = false
                },
                onRun: { entry in
                    onRunHistory(entry)
                    showingHistory = false
                },
                onClear: { model.clearHistory() })
                .tesseraModalBackground()
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No tab open", systemImage: "macwindow")
        } description: {
            Text(connectionOptions.isEmpty
                 ? "Create a connection to get started."
                 : "Double-click a table in the schema to browse it, or press ⌘T for a new query tab.")
        } actions: {
            if connectionOptions.isEmpty {
                Button("New Connection…") { onNewConnection() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("New Query Tab") { model.addTab() }
            }
        }
    }
}
