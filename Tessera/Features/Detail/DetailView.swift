import SwiftUI
import DBKit

/// Column 3 — detail with query tabs, a live SQL editor, Run, the results table,
/// and query history. Each tab has its own editor and result but shares the
/// connection.
struct DetailView: View {
    @Bindable var model: QueryConsoleModel
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            editorToolbar
            Divider()
            editor
            Divider()
            resultsArea
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
                if let tab = model.activeTab { tab.task = Task { await model.run(tab) } }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.status != .ready || (model.activeTab?.isRunning ?? true))
            .keyboardShortcut(.return, modifiers: .command)

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
        SQLEditor(text: sqlBinding)
            .frame(height: 150)
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
        } else if let result = model.activeTab?.result {
            ResultsTableView(result: result)
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
            }
            Spacer()
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
