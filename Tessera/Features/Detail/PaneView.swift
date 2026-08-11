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
    @State private var showConnectionPicker = false
    /// Guarantees the split preview clears when the drag ends (see `DropEndMonitor`).
    @State private var dropEndMonitor = DropEndMonitor()

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
        // SwiftUI can skip both `dropExited` and `performDrop` when a dragged tab
        // is released back onto its own pane, stranding the preview highlight.
        // Arm a mouse-up fallback whenever a preview is showing so it can't stick.
        .onChange(of: dropEdge) { _, edge in
            if edge == nil { dropEndMonitor.disarm() }
            else { dropEndMonitor.arm { dropEdge = nil } }
        }
        .onDisappear { dropEndMonitor.disarm() }
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
                    } else if tab.kind == .redisKeys {
                        redisKeysToolbar(tab)
                    } else {
                        editorToolbar(tab)
                        Divider()
                        editor(tab)
                    }
                    // The editor's height is draggable; the data view's generated
                    // SQL is fixed, so it keeps a plain separator.
                    if tab.kind == .data || tab.kind == .redisKeys {
                        Divider()
                    } else {
                        editorResizeHandle
                    }
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
                // A fixed space for the resize handle: the editor's top edge stays
                // put in it (toolbar height is constant), so tracking the pointer's
                // absolute Y here doesn't feed back as the handle reflows downward.
                .coordinateSpace(name: Self.editorSpace)
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
        Button {
            guard !connectionOptions.isEmpty else { return }
            model.activate(tab)
            showConnectionPicker = true
        } label: {
            Label(tab.session?.name ?? "No connection", systemImage: "cylinder.split.1x2")
        }
        .buttonStyle(.plain).fixedSize().controlSize(.small).pillChrome()
        .help("Connection this tab runs against")
        .popover(isPresented: $showConnectionPicker, arrowEdge: .bottom) {
            ConnectionPickerPopover(
                options: connectionOptions,
                currentID: tab.session?.id,
                isPresented: $showConnectionPicker,
                onSelect: { model.activate(tab); onSelectConnection($0) })
        }
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
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            savedQueriesMenu(tab)
            Button { model.activate(tab); showingHistory = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
            }
            .buttonStyle(.glassPill)
            .help("Query history")
        }
        .animation(.snappy(duration: 0.2), value: tab.isEditable)
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
                  completion: tab.session?.completionEngine,
                  focusTrigger: isFocused ? focusTrigger : 0,
                  cursor: Binding(get: { tab.cursorPosition }, set: { tab.cursorPosition = $0 }),
                  onFocus: { model.activate(tab) })
            .frame(height: currentEditorHeight)
    }

    // MARK: Editor resize

    /// The SQL editor's height, shared across query panes and persisted. `live`
    /// holds the in-flight value during a drag so UserDefaults isn't hit per frame.
    @AppStorage("tessera.editorHeight") private var editorHeight = 150.0
    @State private var liveEditorHeight: CGFloat?
    /// Captured at drag start: pointer-Y minus editor height, i.e. the editor's
    /// fixed top edge. `height = pointerY - offset` then tracks the cursor exactly.
    @State private var editorDragOffset: CGFloat?
    private static let minEditorHeight: CGFloat = 70
    private static let editorSpace = "paneEditorSpace"

    /// Cap the editor so the results area keeps a usable strip; falls back to a
    /// fixed ceiling until the pane's size is known.
    private var maxEditorHeight: CGFloat {
        paneSize.height > 0 ? max(Self.minEditorHeight, paneSize.height - 160) : 600
    }

    private var currentEditorHeight: CGFloat {
        min(max(liveEditorHeight ?? editorHeight, Self.minEditorHeight), maxEditorHeight)
    }

    /// Draggable separator between the editor and the results — grows/shrinks the
    /// editor and persists the height on release.
    private var editorResizeHandle: some View {
        ZStack {
            Divider()
            Color.clear.frame(height: 8).contentShape(Rectangle())
        }
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.editorSpace))
                .onChanged { value in
                    let offset = editorDragOffset ?? (value.location.y - currentEditorHeight)
                    if editorDragOffset == nil { editorDragOffset = offset }
                    liveEditorHeight = min(max(value.location.y - offset,
                                               Self.minEditorHeight), maxEditorHeight)
                }
                .onEnded { _ in
                    if let height = liveEditorHeight { editorHeight = Double(height) }
                    liveEditorHeight = nil
                    editorDragOffset = nil
                })
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
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            filterBar(tab)

            sortMenu(tab)
            limitField(tab)
            explainMenu(tab)
            autoRefreshMenu(tab)

            if tab.isRunning {
                ProgressView().controlSize(.mini)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            savedQueriesMenu(tab)
            Button { model.activate(tab); showingHistory = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
            }
            .buttonStyle(.glassPill)
            .help("Query history")
        }
        .animation(.snappy(duration: 0.2), value: tab.isEditable)
        .animation(.snappy(duration: 0.2), value: tab.isRunning)
    }

    /// The WHERE filter as one search-field-like capsule: funnel icon, the
    /// completing text field, and a clear button once a filter is set. The field
    /// grows with its clause (a followed foreign key writes one in whole) instead
    /// of scrolling inside a fixed box, and an applied filter tints the chrome so
    /// a filtered grid is recognisable at a glance.
    private func filterBar(_ tab: QueryTab) -> some View {
        let active = !tab.filterWhere.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            FilterField(
                text: Binding(get: { tab.filterWhere }, set: { tab.filterWhere = $0 }),
                table: tab.dataTable,
                completion: tab.session?.completionEngine,
                columns: tab.result?.columns.map(\.name) ?? [],
                placeholder: String(localized: "WHERE …"),
                onSubmit: { clause in Task { await model.applyFilter(tab, where: clause) } })
                .frame(width: Self.filterFieldWidth(for: tab.filterWhere), height: 24)
            if active {
                Button {
                    tab.filterWhere = ""
                    Task { await model.applyFilter(tab, where: "") }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.horizontal, 7)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(active ? AnyShapeStyle(Color.accentColor.opacity(0.5))
                                 : AnyShapeStyle(.primary.opacity(0.12))))
        .animation(.snappy(duration: 0.18), value: active)
    }

    /// Width for the filter field: sized to its text (the field's monospaced font)
    /// with room for the caret, clamped so an empty field stays compact and a long
    /// clause caps out instead of pushing every other control off the toolbar.
    private static func filterFieldWidth(for text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return min(max(160, textWidth + 24), 440)
    }

    // MARK: Redis key browser toolbar

    private func redisKeysToolbar(_ tab: QueryTab) -> some View {
        TabToolbar(name: tab.title, systemImage: tab.kind.icon) {
            Button { model.activate(tab); Task { await model.reloadRedisKeys(tab) } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glassPillProminent)
            .disabled(tab.session == nil || tab.isRunning)

            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField(String(""), text: Binding(get: { tab.redisPattern },
                                                set: { tab.redisPattern = $0 }),
                      prompt: Text(verbatim: "MATCH *"))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 220)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
                .onSubmit { Task { await model.reloadRedisKeys(tab) } }

            if tab.isRunning {
                ProgressView().controlSize(.mini)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(.snappy(duration: 0.2), value: tab.isRunning)
    }

    @ViewBuilder
    private func explainMenu(_ tab: QueryTab) -> some View {
        // Redis has no query plans — hide the menu instead of offering a no-op.
        if tab.session?.engine.isKeyValue != true {
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
        SQLEditor(text: .constant(tab.sql), completion: nil, focusTrigger: 0, cursor: nil, readOnly: true)
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

/// Fallback that clears a stranded split-drop preview. SwiftUI sometimes fires
/// neither `dropExited` nor `performDrop` when a dragged tab is released back onto
/// its own pane, so the preview would linger forever. While a preview is on
/// screen this watches for the mouse-up that ends the drag and clears it — a tick
/// late, so a legitimate `performDrop` (which clears the preview itself) wins.
@MainActor
final class DropEndMonitor {
    private var monitor: Any?

    func arm(_ clear: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        // The monitor fires on the main thread; clearing the preview here is safe
        // even if `performDrop` also runs — it reads the drop location, not this
        // state, so the split still lands.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            MainActor.assumeIsolated { clear() }
            return event
        }
    }

    func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
