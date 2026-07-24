import SwiftUI
import DBKit

/// One pane in the tiling layout: its tab bar plus the content of its active tab
/// (editor/data toolbar, results, inspector, pending changes, or a diagram). A tab
/// dragged onto the pane's body splits it — drop near an edge, a preview shows
/// where the new pane will land.
struct PaneView: View {
    @Bindable var model: QueryConsoleModel
    var group: TabGroup
    var isReadOnly: Bool
    var connectionOptions: [ConnectionOption]
    var onSelectConnection: (UUID) -> Void
    var onRun: () -> Void
    var onExplain: (Bool) -> Void
    var onExportResult: (ResultExport.Format) -> Void
    var focusTrigger: Int
    @Binding var showingHistory: Bool
    @Binding var showingSaveQuery: Bool
    @Binding var saveQueryTitle: String
    var canClosePane: Bool
    var onNewConnection: () -> Void

    @State private var dropEdge: DropEdge?
    @State private var paneSize: CGSize = .zero

    private var activeTab: QueryTab? { model.activeTab(in: group) }
    private var isFocused: Bool { model.workspace.focusedGroupID == group.id }

    var body: some View {
        VStack(spacing: 0) {
            DetailTabBar(model: model, group: group,
                         onCloseGroup: canClosePane ? { model.closePane(group.id) } : nil)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Read the pane's size for split-edge maths, behind the content so
                // it never intercepts clicks/scroll.
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { paneSize = geo.size }
                            .onChange(of: geo.size) { _, size in paneSize = size }
                    }
                    .allowsHitTesting(false)
                }
                // The drop lives on the content itself (not a covering overlay), so
                // the editor, grid and toolbar stay fully interactive; the preview
                // is drawn on top but ignores hit-testing.
                .overlay { splitPreview }
                .onDrop(of: [.text], delegate: SplitDropDelegate(
                    size: paneSize, edge: $dropEdge,
                    perform: { edge, id in model.splitDrop(id, into: group.id, edge: edge) }))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let tab = activeTab {
            if tab.kind == .diagram, let diagram = tab.diagram {
                DiagramTabView(model: diagram,
                               onOpenTable: { schema, table in
                                   Task { await model.openTable(schema: schema, table: table, on: tab.session) }
                               },
                               onShowWholeSchema: {
                                   model.openDiagram(schema: diagram.schemaName, on: tab.session)
                               },
                               onRefresh: { Task { await model.refreshDiagram(tab) } })
            } else {
                VStack(spacing: 0) {
                    if tab.kind == .data {
                        dataToolbar(tab)
                        Divider()
                        dataSQLView(tab)
                    } else {
                        editorToolbar(tab)
                        Divider()
                        editor(tab)
                    }
                    Divider()
                    DetailResultsArea(model: model, tab: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if group.showInspector, tab.result != nil {
                        Divider()
                        ValueInspectorPanel(tab: tab)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if tab.hasEdits {
                        Divider()
                        PendingChangesPanel(model: model, tab: tab)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: group.showInspector)
                .animation(.snappy(duration: 0.25), value: tab.hasEdits)
            }
        } else {
            emptyPane
        }
    }

    private var emptyPane: some View {
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
                Button("New Query Tab") { model.addTab(in: group) }
            }
        }
    }

    // MARK: Split drop

    /// The translucent preview of where a dropped tab will land — drawn on top of
    /// the pane, never hit-testable, so it can't swallow interaction.
    @ViewBuilder private var splitPreview: some View {
        if let edge = dropEdge {
            let size = previewSize(edge, paneSize)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: previewAlignment(edge))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: dropEdge)
        }
    }

    private func previewSize(_ edge: DropEdge, _ size: CGSize) -> CGSize {
        switch edge {
        case .left, .right: CGSize(width: size.width / 2, height: size.height)
        case .top, .bottom: CGSize(width: size.width, height: size.height / 2)
        }
    }

    private func previewAlignment(_ edge: DropEdge) -> Alignment {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    // MARK: Toolbars (scoped to this pane's active `tab`)

    @ViewBuilder private func connectionPicker(_ tab: QueryTab) -> some View {
        Menu {
            if connectionOptions.isEmpty {
                Text("No connections")
            } else {
                ForEach(connectionOptions) { option in
                    Button(option.name) { model.activate(tab); onSelectConnection(option.id) }
                }
            }
        } label: {
            Label(tab.session?.name ?? "No connection", systemImage: "cylinder.split.1x2")
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small).pillChrome()
        .help("Connection this tab runs against")
    }

    private func editorToolbar(_ tab: QueryTab) -> some View {
        TabToolbar(name: tab.title, systemImage: tab.kind.icon) {
            connectionPicker(tab)
            Button { model.activate(tab); onRun() } label: {
                let editing = tab.hasEdits
                Label(editing ? "Commit" : "Run", systemImage: editing ? "checkmark" : "play.fill")
            }
            .buttonStyle(.glassPillProminent)
            .disabled(tab.session?.status == .connecting || tab.isRunning || tab.session == nil)

            Button { Task { await model.cancel(tab) } } label: {
                Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(.glassPill)
            .disabled(!tab.isRunning)

            explainMenu(tab)
            autoRefreshMenu(tab)

            if tab.isEditable {
                Button { model.addInsertRow(tab) } label: {
                    Label("Add Row", systemImage: "plus.rectangle")
                }
                .buttonStyle(.glassPill)
            }
            savedQueriesMenu(tab)
            Button { model.activate(tab); showingHistory = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
            }
            .buttonStyle(.glassPill)
            .help("Query history")
        }
    }

    private func savedQueriesMenu(_ tab: QueryTab) -> some View {
        let queries = model.savedQueries.filter { $0.connectionID == nil || $0.connectionID == tab.session?.id }
        return Menu {
            Button {
                model.activate(tab)
                saveQueryTitle = suggestedSaveTitle(tab)
                showingSaveQuery = true
            } label: {
                Label("Save Current Query…", systemImage: "bookmark")
            }
            .disabled(tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !queries.isEmpty {
                Divider()
                ForEach(queries) { query in
                    Button(query.title) { model.activate(tab); model.loadIntoActiveTab(query.sql) }
                }
                Divider()
                Menu {
                    ForEach(queries) { query in
                        Button(query.title, role: .destructive) { model.deleteSavedQuery(query.id) }
                    }
                } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Label("Saved Queries", systemImage: "bookmark").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).controlSize(.small).fixedSize().pillChrome()
        .help("Saved queries")
    }

    private func suggestedSaveTitle(_ tab: QueryTab) -> String {
        let firstLine = tab.sql.split(whereSeparator: \.isNewline)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return String(firstLine.prefix(48))
    }

    private func editor(_ tab: QueryTab) -> some View {
        SQLEditor(text: Binding(get: { tab.sql }, set: { tab.sql = $0 }),
                  schema: model.schema(for: tab),
                  focusTrigger: isFocused ? focusTrigger : 0,
                  cursor: Binding(get: { tab.cursorPosition }, set: { tab.cursorPosition = $0 }),
                  engine: model.engine(for: tab),
                  onFocus: { model.activate(tab) })
            .frame(height: 150)
    }

    // MARK: Data view toolbar

    private func dataToolbar(_ tab: QueryTab) -> some View {
        TabToolbar(name: tab.dataTable ?? tab.title, systemImage: tab.kind.icon) {
            Button { model.activate(tab); onRun() } label: {
                Label(tab.hasEdits ? "Commit" : "Refresh",
                      systemImage: tab.hasEdits ? "checkmark" : "arrow.clockwise")
            }
            .buttonStyle(.glassPillProminent)
            .disabled(tab.session?.status == .connecting || tab.isRunning || tab.session == nil)

            if tab.isEditable {
                Button { model.addInsertRow(tab) } label: {
                    Label("Add Row", systemImage: "plus.rectangle")
                }
                .buttonStyle(.glassPill)
            }

            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            FilterField(
                text: Binding(get: { tab.filterWhere }, set: { tab.filterWhere = $0 }),
                columns: tab.result?.columns.map(\.name) ?? [],
                placeholder: String(localized: "WHERE …"),
                onSubmit: { clause in Task { await model.applyFilter(tab, where: clause) } })
                .frame(width: 160, height: 24)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))

            sortMenu(tab)
            limitField(tab)
            explainMenu(tab)
            autoRefreshMenu(tab)

            if tab.isRunning { ProgressView().controlSize(.mini) }
            savedQueriesMenu(tab)
            Button { model.activate(tab); showingHistory = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
            }
            .buttonStyle(.glassPill)
            .help("Query history")
        }
    }

    private func explainMenu(_ tab: QueryTab) -> some View {
        Menu {
            Button("Explain") { model.activate(tab); onExplain(false) }
            if let dialect = tab.session?.engine.dialect,
               dialect.explainPrefix(analyze: true).prefix != dialect.explainPrefix(analyze: false).prefix {
                Button("Explain Analyze") { model.activate(tab); onExplain(true) }
            }
        } label: {
            Label("Explain", systemImage: "list.bullet.indent")
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small).pillChrome()
        .disabled(tab.session == nil || tab.isRunning)
        .help("Show the query plan (Analyze also executes the statement)")
    }

    private func autoRefreshMenu(_ tab: QueryTab) -> some View {
        Menu {
            Button { model.setAutoRefresh(tab, interval: nil) } label: {
                if tab.autoRefreshInterval == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            Divider()
            ForEach([2.0, 5, 10, 30, 60], id: \.self) { seconds in
                Button { model.setAutoRefresh(tab, interval: seconds) } label: {
                    if tab.autoRefreshInterval == seconds {
                        Label(Self.intervalLabel(seconds), systemImage: "checkmark")
                    } else {
                        Text(Self.intervalLabel(seconds))
                    }
                }
            }
        } label: {
            Label("Auto-refresh", systemImage: "timer").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small).pillChrome()
        .foregroundStyle(tab.autoRefreshInterval != nil ? Color.accentColor : Color.secondary)
        .help("Re-run this query automatically")
    }

    private static func intervalLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "1 min"
    }

    private func sortMenu(_ tab: QueryTab) -> some View {
        let columns = tab.result?.columns.map(\.name) ?? []
        // Label shows the primary sort, with a "+N" when more columns break ties.
        let label: String
        if let primary = tab.sortOrder.first {
            let extra = tab.sortOrder.count - 1
            label = "\(primary.column) \(primary.ascending ? "↑" : "↓")" + (extra > 0 ? " +\(extra)" : "")
        } else {
            label = String(localized: "Sort")
        }
        return Menu {
            ForEach(columns, id: \.self) { column in
                Button { Task { await model.sortByColumn(tab, column: column) } } label: {
                    if let key = tab.sortOrder.first(where: { $0.column == column }),
                       let rank = tab.sortOrder.firstIndex(where: { $0.column == column }) {
                        // Show priority (1-based) and direction for a sorted column.
                        Label("\(rank + 1). \(column)", systemImage: key.ascending ? "arrow.up" : "arrow.down")
                    } else { Text(column) }
                }
            }
            if !tab.sortOrder.isEmpty {
                Divider()
                Button("Clear Sort") { Task { await model.clearSort(tab) } }
            }
        } label: {
            Label(label, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small).pillChrome()
        .help("Sort by a column")
    }

    private func limitField(_ tab: QueryTab) -> some View {
        HStack(spacing: 3) {
            Text("Limit").font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { tab.pageLimit }, set: { tab.pageLimit = max(1, $0) }),
                      format: .number)
                .textFieldStyle(.plain)
                .padding(.horizontal, 6).padding(.vertical, 3).frame(width: 64)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
                .onSubmit { Task { await model.setLimit(tab, tab.pageLimit) } }
        }
    }

    private func dataSQLView(_ tab: QueryTab) -> some View {
        // Flush, like the query editor — no boxed chrome around the generated SQL.
        SQLEditor(text: .constant(tab.sql), schema: nil, focusTrigger: 0, cursor: nil, readOnly: true)
            .frame(height: 52)
    }
}

/// Reads the pointer's nearest edge inside a pane and splits it there on drop.
private struct SplitDropDelegate: DropDelegate {
    let size: CGSize
    @Binding var edge: DropEdge?
    let perform: (DropEdge, UUID) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = Self.edge(for: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = Self.edge(for: info.location, in: size)
        edge = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let id = UUID(uuidString: string) else { return }
            DispatchQueue.main.async { perform(target, id) }
        }
        return true
    }

    /// The pane is split into four triangles from its centre; the pointer's triangle
    /// picks the edge.
    static func edge(for point: CGPoint, in size: CGSize) -> DropEdge {
        let fx = point.x / max(size.width, 1)
        let fy = point.y / max(size.height, 1)
        let distances: [(DropEdge, CGFloat)] = [
            (.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }
}
