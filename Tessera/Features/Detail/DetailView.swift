import SwiftUI
import DBKit

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

    private var isDataView: Bool { model.activeTab?.kind == .data }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let tab = model.activeTab, tab.kind == .data {
                dataToolbar(tab)
            } else {
                editorToolbar
                Divider()
                editor
            }
            Divider()
            resultsArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let tab = model.activeTab, tab.hasEdits {
                Divider()
                pendingPanel(tab)
            }
            statusBar
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(history: model.history) { sql in
                model.loadIntoActiveTab(sql)
                showingHistory = false
            }
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
        return HStack(spacing: 6) {
            if tab.isRunning {
                ProgressView().controlSize(.mini)
            } else if tab.kind == .data {
                Image(systemName: "tablecells").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
            if model.tabs.count > 1 {
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(isActive ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabID = tab.id }
    }

    // MARK: Editor

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            Button {
                onRun()
            } label: {
                let editing = model.activeTab?.hasEdits == true
                Label(editing ? "Commit" : "Run", systemImage: editing ? "checkmark" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.status != .ready || (model.activeTab?.isRunning ?? true))

            Button {
                model.activeTab?.task?.cancel()
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
            Button {
                showingHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.small)
        }
        .padding(6)
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
            .disabled(model.status != .ready || tab.isRunning)

            if tab.isEditable {
                Button {
                    model.addInsertRow(tab)
                } label: {
                    Label("Add Row", systemImage: "plus.rectangle")
                }
                .controlSize(.small)
            }

            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("WHERE …", text: Binding(get: { tab.filterWhere }, set: { tab.filterWhere = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: 320)
                .onSubmit { Task { await model.applyFilter(tab, where: tab.filterWhere) } }

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

    /// Persistent preview of the exact SQL that ⌘↩ will run.
    private func pendingPanel(_ tab: QueryTab) -> some View {
        let statements = model.pendingStatements(tab)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Pending changes", systemImage: "pencil.and.list.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘↩ to commit").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(statements.isEmpty ? "— nothing to write —" : statements.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(height: 120)
        .background(.quaternary.opacity(0.4))
    }

    private var sqlBinding: Binding<String> {
        Binding(get: { model.activeTab?.sql ?? "" }, set: { model.activeTab?.sql = $0 })
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        if let tab = model.activeTab, tab.result != nil {
            // A failed re-run keeps the previous result (and its selection) visible;
            // the error shows as a banner above the grid.
            VStack(spacing: 0) {
                if let message = tab.errorMessage {
                    errorBanner(message)
                    Divider()
                }
                ResultsTableView(tab: tab) { column in
                    Task { await model.sortByColumn(tab, column: column) }
                }
            }
        } else if let message = model.activeTab?.errorMessage {
            ContentUnavailableView {
                Label("Query failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.callout.monospaced()).textSelection(.enabled)
            }
        } else {
            ContentUnavailableView("No results", systemImage: "tablecells",
                                   description: Text("Press Run to execute the query."))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(message).font(.callout.monospaced()).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
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
                    if canLoadMore(tab, loaded: result.rows.count) {
                        Button("Load more") { Task { await model.loadMore(tab) } }
                            .buttonStyle(.link)
                    }
                } else if let result = model.activeTab?.result {
                    Text("\(result.rows.count) rows")
                    Text("\(result.columns.count) columns")
                } else {
                    Text("Ready")
                }
                if let tab = model.activeTab, tab.hasEdits {
                    let updates = tab.edits.keys.filter { !tab.pendingDeletes.contains($0) }.count
                    Text(pendingSummary(updates: updates, deletes: tab.pendingDeletes.count))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
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
