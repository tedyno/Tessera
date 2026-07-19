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

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            editorToolbar
            Divider()
            editor
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
        if let message = model.activeTab?.errorMessage {
            ContentUnavailableView {
                Label("Query failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.callout.monospaced())
            }
        } else if let tab = model.activeTab, tab.result != nil {
            ResultsTableView(tab: tab)
        } else {
            ContentUnavailableView("No results", systemImage: "tablecells",
                                   description: Text("Press Run to execute the query."))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            switch model.status {
            case .idle: Text("Idle")
            case .connecting: Text("Connecting…")
            case .failed: Text("Connection error")
            case .ready:
                if let result = model.activeTab?.result {
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
