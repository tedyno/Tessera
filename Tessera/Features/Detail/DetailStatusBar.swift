import SwiftUI
import DBKit

/// The always-present bottom bar of the detail column: connection identity, the
/// live status/row-count summary, pending-edit summary, and the row-density /
/// inspector / export / log affordances.
struct DetailStatusBar: View {
    @Bindable var model: QueryConsoleModel
    let jobs: BackgroundJobsModel
    var isReadOnly: Bool
    /// Grid row density; compact matches a terminal, comfortable breathes. Shared
    /// via the `tessera.gridDensity` key with the results grid and the Appearance
    /// settings tab.
    @AppStorage("tessera.gridDensity") private var gridComfortable = false
    @Binding var showingConnectionLog: Bool
    var onExportResult: (ResultExport.Format) -> Void
    @State private var showingExportMenu = false

    /// The inspector toggle acts on whichever pane has focus — its state lives on
    /// the group, so the shared status bar drives the right pane.
    private var showInspector: Bool { model.workspace.focusedGroup?.showInspector ?? false }

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
                        .animation(.easeInOut(duration: 0.25), value: idle)
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
                if let tab = model.activeTab, tab.kind == .data || tab.kind == .redisKeys,
                   let result = tab.result {
                    Group {
                        if let total = tab.totalRows {
                            Text("\(result.rows.count) of \(total) rows")
                        } else {
                            Text("\(result.rows.count) rows")
                        }
                    }
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: result.rows.count)
                    if let ms = tab.elapsedMS, tab.isRunning == false {
                        Text("\(ms) ms").foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.25), value: ms)
                    }
                    if tab.hasMoreRows {
                        Button("Load more") { Task { await model.loadMore(tab) } }
                            .buttonStyle(.link)
                    }
                } else if let result = model.activeTab?.result, result.columns.isEmpty {
                    // A statement with no result set (UPDATE/INSERT/DELETE/DDL).
                    if let affected = result.rowsAffected {
                        Text("^[\(affected) row](inflect: true) affected").foregroundStyle(.green)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.25), value: affected)
                    } else {
                        Text("Executed").foregroundStyle(.green)
                    }
                    if let ms = model.activeTab?.elapsedMS {
                        Text("\(ms) ms").foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.25), value: ms)
                    }
                } else if let result = model.activeTab?.result {
                    Text("\(result.rows.count) rows")
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: result.rows.count)
                    Text("\(result.columns.count) columns")
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: result.columns.count)
                    if let ms = model.activeTab?.elapsedMS, model.activeTab?.isRunning == false {
                        Text("\(ms) ms").foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.25), value: ms)
                    }
                    if result.isTruncated {
                        Label("truncated at the row limit", systemImage: "scissors")
                            .foregroundStyle(.orange)
                            .help("Raise “Max rows per query” in Settings to fetch more.")
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    if model.activeTab?.resultIsReadOnly == true {
                        Label("read-only", systemImage: "pencil.slash")
                            .foregroundStyle(.secondary)
                            .help("This result can’t be edited — only a query that reads from a single table is editable.")
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
            // Work that outlives the click that started it — exports, dumps,
            // restores — lives here rather than in whichever tab happened to start
            // it, because it keeps running after you switch away.
            BackgroundJobsIndicator(jobs: jobs)
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
                Button { model.workspace.focusedGroup?.showInspector.toggle() } label: {
                    Label("Inspect Cell", systemImage: "rectangle.and.text.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showInspector ? Color.accentColor : .secondary)
                .help("Show the value inspector for the selected cell")
                // A plain Button (not a Menu) so it's visually identical to the
                // neighbouring icon buttons — `Menu` renders its label as a larger,
                // brighter control that ignores the inherited font and tint. The
                // format choices live in a popover.
                Button { showingExportMenu = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Export these results to a file")
                .popover(isPresented: $showingExportMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        exportRow("CSV…", .csv)
                        exportRow("Excel…", .xlsx)
                        exportRow("JSON…", .json)
                        exportRow("SQL INSERT…", .sql)
                    }
                    .padding(6)
                    .frame(minWidth: 130)
                }
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
        // Reflow the summary when the connection state flips (Idle → Connecting →
        // rows) and when the editability/limit badges come and go, so text and
        // badges slide in rather than snapping.
        .animation(.snappy(duration: 0.25), value: model.status)
        .animation(.snappy(duration: 0.2), value: model.activeTab?.resultIsReadOnly)
        .animation(.snappy(duration: 0.2), value: model.activeTab?.result?.isTruncated)
        // Clear of the window's rounded bottom corners — 12 pt let the first
        // item hug the curve.
        .padding(.horizontal, 18)
        // Fixed height so the footer stays the same across tab kinds, regardless of
        // which (result-only) buttons are present.
        .frame(height: TabChrome.statusBarHeight)
    }

    private func exportRow(_ title: LocalizedStringKey, _ format: ResultExport.Format) -> some View {
        Button {
            showingExportMenu = false
            onExportResult(format)
        } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func pendingSummary(updates: Int, deletes: Int) -> String {
        var parts: [String] = []
        if updates > 0 { parts.append(String(localized: "\(updates) to update")) }
        if deletes > 0 { parts.append(String(localized: "\(deletes) to delete")) }
        return parts.joined(separator: ", ") + String(localized: " — ⌘↩ to commit")
    }
}
