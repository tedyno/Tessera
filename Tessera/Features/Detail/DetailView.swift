import SwiftUI
import DBKit

/// Column 3 — detail with tabs, SQL editor and results table. Phase 1: the editor
/// is live and Run executes a real query against the local Postgres via
/// `QueryConsoleModel`; results render in a dynamic-column `Table`. Syntax
/// highlighting (STTextView) and streaming for large sets arrive in Phases 7/8.
struct DetailView: View {
    @Bindable var model: QueryConsoleModel

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
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tab("orders", active: true)
            tab("customers", active: false)
            Spacer()
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tab(_ title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(active ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
        .overlay(alignment: .trailing) { Divider() }
    }

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.run() }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.status != .ready)
            .keyboardShortcut(.return, modifiers: .command)

            Button { } label: { Label("Stop", systemImage: "stop.fill") }
                .controlSize(.small)
                .disabled(true)

            if model.status == .running {
                ProgressView().controlSize(.small)
            } else if let ms = model.elapsedMS {
                Text("\(ms) ms").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(6)
    }

    private var editor: some View {
        TextEditor(text: $model.sql)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 150)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let message = model.errorMessage {
            ContentUnavailableView {
                Label("Query failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.callout.monospaced())
            }
        } else if let result = model.result {
            ResultsTable(result: result)
        } else {
            ContentUnavailableView(
                "No results",
                systemImage: "tablecells",
                description: Text("Press Run to execute the query.")
            )
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            switch model.status {
            case .idle: Text("Idle")
            case .connecting: Text("Connecting…")
            case .running: Text("Running…")
            case .ready:
                if let result = model.result {
                    Text("\(result.rows.count) rows")
                    Text("\(result.columns.count) columns")
                } else {
                    Text("Ready")
                }
            case .failed: Text("Error")
            }
            Spacer()
            Text("PostgreSQL · \(model.status == .ready ? "connected" : "—")")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

/// Renders a `QueryResult` in a native `Table` with columns known only at runtime.
private struct ResultsTable: View {
    let result: QueryResult

    private struct Row: Identifiable {
        let id: Int
        let cells: [Cell]
    }

    private var rows: [Row] {
        result.rows.enumerated().map { Row(id: $0.offset, cells: $0.element) }
    }

    var body: some View {
        Table(rows) {
            TableColumnForEach(Array(result.columns.indices), id: \.self) { index in
                TableColumn(result.columns[index].name) { (row: Row) in
                    let cell = index < row.cells.count ? row.cells[index] : Cell.null
                    if let text = cell.text {
                        Text(text).monospaced()
                    } else {
                        Text("NULL").foregroundStyle(.tertiary).italic()
                    }
                }
            }
        }
    }
}
