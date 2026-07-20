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
struct DetailView: View {
    @Bindable var model: QueryConsoleModel
    @Binding var showingHistory: Bool
    var focusTrigger: Int
    var cursor: Binding<Int>
    var isReadOnly: Bool = false
    var onRun: () -> Void
    var onExportResult: (ResultExport.Format) -> Void = { _ in }
    /// History actions route to the connection each entry came from.
    var onPickHistory: (QueryHistoryEntry) -> Void = { _ in }
    var onRunHistory: (QueryHistoryEntry) -> Void = { _ in }
    /// Connections a tab can target, and the action to point the active tab at one.
    var connectionOptions: [ConnectionOption] = []
    var onSelectConnection: (UUID) -> Void = { _ in }

    /// Whether the value inspector panel is shown below the results grid.
    @State private var showInspector = false
    @State private var showingSaveQuery = false
    @State private var saveQueryTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if model.activeTab == nil {
                emptyState
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
                resultsArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector, let tab = model.activeTab, tab.result != nil {
                    Divider()
                    inspectorPanel(tab)
                }
                if let tab = model.activeTab, tab.hasEdits {
                    Divider()
                    pendingPanel(tab)
                }
            }
            statusBar
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
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No tab open", systemImage: "macwindow")
        } description: {
            Text("Double-click a table in the schema to browse it, or press ⌘T for a new query tab.")
        } actions: {
            Button("New Query Tab") { model.addTab() }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    tabChip(tab)
                }
                Button {
                    model.addTab()
                } label: {
                    Image(systemName: "plus").padding(.horizontal, 10)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tabChip(_ tab: QueryTab) -> some View {
        let isActive = tab.id == model.activeTabID
        let isData = tab.kind == .data
        // Label each tab with its connection when more than one is open, so the same
        // table from staging vs production is distinguishable.
        let showConnection = model.sessions.count > 1
        return HStack(spacing: 6) {
            if tab.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: isData ? "tablecells" : "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(isData ? AnyShapeStyle(.teal) : AnyShapeStyle(.secondary))
            }
            if showConnection, let session = tab.session {
                Circle().fill(connectionColor(session)).frame(width: 7, height: 7)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
            if showConnection, let session = tab.session {
                Text(session.qualifiedName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.pathLabel)
            }
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Close tab")
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(isActive
                    ? (isData ? AnyShapeStyle(Color.teal.opacity(0.12)) : AnyShapeStyle(.background))
                    : AnyShapeStyle(.clear))
        // A teal top-stripe marks data views apart from SQL console tabs.
        .overlay(alignment: .top) {
            if isData { Rectangle().fill(.teal).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabID = tab.id }
        .overlay { MiddleClickCatcher { model.closeTab(tab.id) } }
        .contextMenu { tabMenu(tab) }
    }

    @ViewBuilder
    private func tabMenu(_ tab: QueryTab) -> some View {
        Button("Close") { model.closeTab(tab.id) }
            .keyboardShortcut("w", modifiers: .command)
        Button("Close Other Tabs") { model.closeOtherTabs(tab.id) }
            .disabled(model.tabs.count < 2)
        Button("Close All Tabs") { model.closeAllTabs() }
        Divider()
        Button("Close Tabs to the Left") { model.closeTabsToLeft(of: tab.id) }
            .disabled(!model.hasTabs(toLeftOf: tab.id))
        Button("Close Tabs to the Right") { model.closeTabsToRight(of: tab.id) }
            .disabled(!model.hasTabs(toRightOf: tab.id))
    }

    // MARK: Editor

    /// Which connection the active tab runs against — pick one even before anything
    /// is connected.
    @ViewBuilder private var connectionPicker: some View {
        Menu {
            if connectionOptions.isEmpty {
                Text("No connections")
            } else {
                ForEach(connectionOptions) { option in
                    Button(option.name) { onSelectConnection(option.id) }
                }
            }
        } label: {
            Label(model.activeTab?.session?.name ?? "No connection",
                  systemImage: "cylinder.split.1x2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Connection this tab runs against")
    }

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            connectionPicker

            Button {
                onRun()
            } label: {
                let editing = model.activeTab?.hasEdits == true
                Label(editing ? "Commit" : "Run", systemImage: editing ? "checkmark" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.status == .connecting || (model.activeTab?.isRunning ?? true)
                      || model.activeTab?.session == nil)

            Button {
                if let tab = model.activeTab { Task { await model.cancel(tab) } }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.small)
            .disabled(!(model.activeTab?.isRunning ?? false))

            if model.activeTab?.isEditable == true {
                Button {
                    if let tab = model.activeTab { model.addInsertRow(tab) }
                } label: {
                    Label("Add Row", systemImage: "plus.rectangle")
                }
                .controlSize(.small)
            }

            if let ms = model.activeTab?.elapsedMS, model.activeTab?.isRunning == false {
                Text("\(ms) ms").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            savedQueriesMenu
            Button {
                showingHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.small)
        }
        .padding(6)
        .alert("Save Query", isPresented: $showingSaveQuery) {
            TextField("Name", text: $saveQueryTitle)
            Button("Save") {
                if let sql = model.activeTab?.sql { model.saveQuery(title: saveQueryTitle, sql: sql) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this query a name to find it later.")
        }
    }

    private var savedQueriesMenu: some View {
        Menu {
            Button {
                saveQueryTitle = suggestedSaveTitle
                showingSaveQuery = true
            } label: {
                Label("Save Current Query…", systemImage: "bookmark")
            }
            .disabled((model.activeTab?.sql ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !model.savedQueries.isEmpty {
                Divider()
                ForEach(model.savedQueries) { query in
                    Button(query.title) { model.loadIntoActiveTab(query.sql) }
                }
                Divider()
                Menu {
                    ForEach(model.savedQueries) { query in
                        Button(query.title, role: .destructive) { model.deleteSavedQuery(query.id) }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Label("Saved Queries", systemImage: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    /// A default bookmark name: the first non-empty line of the current SQL, trimmed.
    private var suggestedSaveTitle: String {
        let sql = model.activeTab?.sql ?? ""
        let firstLine = sql.split(whereSeparator: \.isNewline)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return String(firstLine.prefix(48))
    }

    private var editor: some View {
        SQLEditor(text: sqlBinding, schema: model.schema, focusTrigger: focusTrigger, cursor: cursor)
            .frame(height: 150)
    }

    // MARK: Data view toolbar

    /// Toolbar for a data view: a WHERE filter, refresh/commit, and row insertion —
    /// no SQL editor. The query is generated from the table, filter, sort, and limit.
    private func dataToolbar(_ tab: QueryTab) -> some View {
        HStack(spacing: 10) {
            Button {
                onRun()
            } label: {
                Label(tab.hasEdits ? "Commit" : "Refresh",
                      systemImage: tab.hasEdits ? "checkmark" : "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.status == .connecting || tab.isRunning || tab.session == nil)

            if tab.isEditable {
                Button {
                    model.addInsertRow(tab)
                } label: {
                    Label("Add Row", systemImage: "plus.rectangle")
                }
                .controlSize(.small)
            }

            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            FilterField(
                text: Binding(get: { tab.filterWhere }, set: { tab.filterWhere = $0 }),
                columns: tab.result?.columns.map(\.name) ?? [],
                placeholder: String(localized: "WHERE …"),
                onSubmit: { clause in Task { await model.applyFilter(tab, where: clause) } })
                .frame(width: 260, height: 24)

            sortMenu(tab)
            limitField(tab)

            if tab.isRunning { ProgressView().controlSize(.mini) }
            Spacer()
            Button {
                showingHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.small)
        }
        .padding(6)
    }

    /// Column sort picker for a data view (mirrors header-click sorting).
    private func sortMenu(_ tab: QueryTab) -> some View {
        let columns = tab.result?.columns.map(\.name) ?? []
        let label = tab.sortColumn.map { "\($0) \(tab.sortAscending ? "↑" : "↓")" } ?? String(localized: "Sort")
        return Menu {
            ForEach(columns, id: \.self) { column in
                Button {
                    Task { await model.sortByColumn(tab, column: column) }
                } label: {
                    if tab.sortColumn == column {
                        Label(column, systemImage: tab.sortAscending ? "arrow.up" : "arrow.down")
                    } else {
                        Text(column)
                    }
                }
            }
            if tab.sortColumn != nil {
                Divider()
                Button("Clear Sort") { Task { await model.clearSort(tab) } }
            }
        } label: {
            Label(label, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Sort by a column")
    }

    /// Editable row limit for a data view, overriding the paging default.
    private func limitField(_ tab: QueryTab) -> some View {
        HStack(spacing: 3) {
            Text("Limit").font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { tab.pageLimit },
                set: { tab.pageLimit = max(1, $0) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .onSubmit { Task { await model.setLimit(tab, tab.pageLimit) } }
        }
    }

    /// The data view's generated query, shown read-only (highlighted, selectable)
    /// so it's always visible like the console editor but can't be edited.
    private func dataSQLView(_ tab: QueryTab) -> some View {
        SQLEditor(text: .constant(tab.sql), schema: nil, focusTrigger: 0, cursor: nil, readOnly: true)
            .frame(height: 52)
            .background(.quaternary.opacity(0.25))
    }

    /// More rows are available when the page came back full and we're below the total.
    private func canLoadMore(_ tab: QueryTab, loaded: Int) -> Bool {
        guard loaded >= tab.pageLimit else { return false }
        if let total = tab.totalRows { return loaded < total }
        return true
    }

    private func pendingSummary(updates: Int, deletes: Int) -> String {
        var parts: [String] = []
        if updates > 0 { parts.append("\(updates) to update") }
        if deletes > 0 { parts.append("\(deletes) to delete") }
        return parts.joined(separator: ", ") + " — ⌘↩ to commit"
    }

    /// Persistent list of the exact statements ⌘↩ will run — each with its own
    /// discard (×) button, plus a Discard-All shortcut.
    private func pendingPanel(_ tab: QueryTab) -> some View {
        let changes = model.pendingChanges(tab)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Pending changes", systemImage: "pencil.and.list.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    model.discardPending(tab)
                } label: {
                    Label("Discard All", systemImage: "trash")
                }
                .controlSize(.small)
                Text("⌘↩ to commit").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes) { change in
                        HStack(spacing: 6) {
                            Button {
                                model.revert(tab, change.target)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Discard this change")

                            Circle().fill(color(for: change.target)).frame(width: 6, height: 6)
                            Text(change.statement)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(height: 120)
        .background(.quaternary.opacity(0.4))
    }

    /// The tab's connection dot reflects live status: green connected, yellow
    /// connecting, red failed, grey disconnected.
    private func connectionColor(_ session: ConnectionSession) -> Color {
        switch session.status {
        case .ready: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .secondary
        }
    }

    /// Dot color matching the row highlight: red delete, orange update, green insert.
    private func color(for target: PendingChange.Target) -> Color {
        switch target {
        case .delete: .red
        case .update: .orange
        case .insert: .green
        }
    }

    private var sqlBinding: Binding<String> {
        Binding(get: { model.activeTab?.sql ?? "" }, set: { model.activeTab?.sql = $0 })
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        if let tab = model.activeTab, tab.result != nil || tab.errorMessage != nil {
            // Error (red) and success (green) share the same banner at the top; a
            // row-returning result shows its grid below, keeping any prior grid on error.
            VStack(spacing: 0) {
                if let message = tab.errorMessage {
                    feedbackBanner(message, isError: true)
                    Divider()
                } else if let result = tab.result, result.columns.isEmpty {
                    feedbackBanner(successText(tab, result), isError: false)
                    Divider()
                }
                if let result = tab.result, !result.columns.isEmpty {
                    ResultsTableView(
                        tab: tab,
                        onSort: { column in
                            Task { await model.sortByColumn(tab, column: column) }
                        },
                        onFollowForeignKey: { target, clause in
                            Task {
                                await model.openReferencedTable(schema: target.schema,
                                                                table: target.table,
                                                                where: clause)
                            }
                        })
                } else {
                    Spacer(minLength: 0)
                }
            }
        } else {
            ContentUnavailableView("No results", systemImage: "tablecells",
                                   description: Text("Press Run to execute the query."))
        }
    }

    private func successText(_ tab: QueryTab, _ result: QueryResult) -> String {
        var parts = [String(localized: "Query executed")]
        if let affected = result.rowsAffected {
            parts.append("\(affected) " + (affected == 1 ? String(localized: "row affected")
                                                         : String(localized: "rows affected")))
        }
        if let ms = tab.elapsedMS { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }

    /// Result feedback banner: red for an error, green for a successful command.
    private func feedbackBanner(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(message)
                    .font(isError ? .callout.monospaced() : .callout)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.red : Color.green).opacity(0.12))
    }

    // MARK: Value inspector

    @ViewBuilder
    private func inspectorPanel(_ tab: QueryTab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cell = tab.inspected {
                HStack(spacing: 6) {
                    Text(cell.column).font(.caption.bold())
                    if !cell.typeName.isEmpty {
                        Text(cell.typeName).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let value = cell.value {
                        Text("\(value.count) chars").font(.caption2).foregroundStyle(.tertiary)
                        Button { copyToPasteboard(value) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy value")
                    }
                }
                Divider()
                ScrollView {
                    Group {
                        if let value = cell.value {
                            Text(inspectorText(value)).font(.callout.monospaced())
                        } else {
                            Text("NULL").font(.callout.monospaced().italic()).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a single cell to inspect its value.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(height: 150)
        .background(.background)
    }

    /// Pretty-prints a value that is valid JSON; otherwise returns it unchanged.
    private func inspectorText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else { return raw }
        return string
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            switch model.status {
            case .idle: Text("Idle")
            case .connecting: Text("Connecting…")
            case .failed: Text("Connection error")
            case .ready:
                if let tab = model.activeTab, tab.kind == .data, let result = tab.result {
                    if let total = tab.totalRows {
                        Text("\(result.rows.count) of \(total) rows")
                    } else {
                        Text("\(result.rows.count) rows")
                    }
                    if let ms = tab.elapsedMS, tab.isRunning == false {
                        Text("\(ms) ms").foregroundStyle(.secondary)
                    }
                    if canLoadMore(tab, loaded: result.rows.count) {
                        Button("Load more") { Task { await model.loadMore(tab) } }
                            .buttonStyle(.link)
                    }
                } else if let result = model.activeTab?.result, result.columns.isEmpty {
                    // A statement with no result set (UPDATE/INSERT/DELETE/DDL).
                    if let affected = result.rowsAffected {
                        Text("^[\(affected) row](inflect: true) affected").foregroundStyle(.green)
                    } else {
                        Text("Executed").foregroundStyle(.green)
                    }
                    if let ms = model.activeTab?.elapsedMS { Text("\(ms) ms").foregroundStyle(.secondary) }
                } else if let result = model.activeTab?.result {
                    Text("\(result.rows.count) rows")
                    Text("\(result.columns.count) columns")
                    if result.isTruncated {
                        Label("truncated at the row limit", systemImage: "scissors")
                            .foregroundStyle(.orange)
                            .help("Raise “Max rows per query” in Settings to fetch more.")
                    }
                } else {
                    Text("Ready")
                }
                if let tab = model.activeTab, tab.hasEdits {
                    let updates = tab.edits.keys.filter { !tab.pendingDeletes.contains($0) }.count
                    Text(pendingSummary(updates: updates, deletes: tab.pendingDeletes.count))
                        .foregroundStyle(.orange)
                } else if let summary = model.activeTab?.scriptSummary {
                    Text(summary).foregroundStyle(.green)
                }
            }
            Spacer()
            if model.activeTab?.result != nil {
                Button { showInspector.toggle() } label: {
                    Label("Inspect Cell", systemImage: "rectangle.and.text.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showInspector ? Color.accentColor : .secondary)
                .help("Show the value inspector for the selected cell")
                Menu {
                    Button("CSV…") { onExportResult(.csv) }
                    Button("Excel…") { onExportResult(.xlsx) }
                    Button("JSON…") { onExportResult(.json) }
                    Button("SQL INSERT…") { onExportResult(.sql) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Export these results to a file")
            }
            if isReadOnly {
                Label("read-only", systemImage: "lock.fill").foregroundStyle(.orange)
            }
            if let engine = model.engine, let version = model.serverVersion {
                Text("\(engine.displayName) \(version)")
            }
            if let name = model.connectionName {
                Text(name).foregroundStyle(model.status == .ready ? .green : .secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
