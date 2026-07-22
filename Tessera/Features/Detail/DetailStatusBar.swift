import SwiftUI
import DBKit

/// The always-present bottom bar of the detail column: connection identity, the
/// live status/row-count summary, pending-edit summary, and the row-density /
/// inspector / export / log affordances.
struct DetailStatusBar: View {
    @Bindable var model: QueryConsoleModel
    var isReadOnly: Bool
    /// Grid row density; compact matches a terminal, comfortable breathes. Shared
    /// via the `tessera.gridDensity` key with the results grid and the Appearance
    /// settings tab.
    @AppStorage("tessera.gridDensity") private var gridComfortable = false
    @Binding var showInspector: Bool
    @Binding var showingConnectionLog: Bool
    var onExportResult: (ResultExport.Format) -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Which database this bar describes, by its organizer colour — the
            // SAME session `model.status` reads, or the dot would name A while
            // the text right next to it reports B's status. Dimmed when idle:
            // identity without implying a live connection.
            if let session = model.activeSession ?? model.activeTab?.session {
                let idle = !session.isReady && !session.isConnecting
                HStack(spacing: 5) {
                    Circle()
                        .fill((ConnectionPalette.color(session.colorName) ?? .secondary)
                            .opacity(idle ? 0.35 : 1))
                        .frame(width: 7, height: 7)
                    Text(session.qualifiedName)
                        .foregroundStyle(idle ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .help(session.pathLabel)
            }
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
                Button { gridComfortable.toggle() } label: {
                    Label("Row Density",
                          systemImage: gridComfortable
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(gridComfortable ? "Compact rows" : "Comfortable rows")
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
            Button { showingConnectionLog = true } label: {
                Label("Log", systemImage: model.connectionLog.hasRecentFailure
                      ? "exclamationmark.triangle.fill" : "text.alignleft")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.connectionLog.hasRecentFailure ? Color.red : .secondary)
            .help("Show what happened while connecting")

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
        // Clear of the window's rounded bottom corners — 12 pt let the first
        // item hug the curve.
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
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
}
