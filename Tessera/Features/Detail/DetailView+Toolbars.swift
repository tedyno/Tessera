import SwiftUI
import DBKit

/// The detail column's toolbars and SQL editors: the console editor toolbar, the
/// data-view toolbar, and the menus (Explain, auto-refresh, Saved Queries, sort)
/// they share. Kept in an extension so they stay on `DetailView` alongside the
/// state they drive (`showingHistory`, `showingSaveQuery`, `onRun`, …).
extension DetailView {
    // MARK: Console editor toolbar

    /// Which connection the active tab runs against — pick one even before anything
    /// is connected.
    @ViewBuilder var connectionPicker: some View {
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
        .pillChrome()
        .help("Connection this tab runs against")
    }

    var editorToolbar: some View {
        HStack(spacing: 10) {
            connectionPicker

            Button {
                onRun()
            } label: {
                let editing = model.activeTab?.hasEdits == true
                Label(editing ? "Commit" : "Run", systemImage: editing ? "checkmark" : "play.fill")
            }
            .buttonStyle(.glassPillProminent)
            .disabled(model.status == .connecting || (model.activeTab?.isRunning ?? true)
                      || model.activeTab?.session == nil)

            Button {
                if let tab = model.activeTab { Task { await model.cancel(tab) } }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassPill)
            .disabled(!(model.activeTab?.isRunning ?? false))

            explainMenu
            if let tab = model.activeTab { autoRefreshMenu(tab) }

            if model.activeTab?.isEditable == true {
                Button {
                    if let tab = model.activeTab { model.addInsertRow(tab) }
                } label: {
                    Label("Add Row", systemImage: "plus.rectangle")
                }
                .buttonStyle(.glassPill)
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
            .buttonStyle(.glassPill)
        }
        .padding(6)
    }

    var savedQueriesMenu: some View {
        let queries = model.savedQueriesForActiveConnection
        return Menu {
            Button {
                saveQueryTitle = suggestedSaveTitle
                showingSaveQuery = true
            } label: {
                Label("Save Current Query…", systemImage: "bookmark")
            }
            .disabled((model.activeTab?.sql ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !queries.isEmpty {
                Divider()
                ForEach(queries) { query in
                    Button(query.title) { model.loadIntoActiveTab(query.sql) }
                }
                Divider()
                Menu {
                    ForEach(queries) { query in
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
        .pillChrome()
    }

    /// A default bookmark name: the first non-empty line of the current SQL, trimmed.
    var suggestedSaveTitle: String {
        let sql = model.activeTab?.sql ?? ""
        let firstLine = sql.split(whereSeparator: \.isNewline)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return String(firstLine.prefix(48))
    }

    var editor: some View {
        SQLEditor(text: sqlBinding, schema: model.schema, focusTrigger: focusTrigger, cursor: cursor,
                  engine: model.engine)
            .frame(height: 150)
    }

    private var sqlBinding: Binding<String> {
        Binding(get: { model.activeTab?.sql ?? "" }, set: { model.activeTab?.sql = $0 })
    }

    // MARK: Data view toolbar

    /// Toolbar for a data view: a WHERE filter, refresh/commit, and row insertion —
    /// no SQL editor. The query is generated from the table, filter, sort, and limit.
    func dataToolbar(_ tab: QueryTab) -> some View {
        HStack(spacing: 10) {
            Button {
                onRun()
            } label: {
                Label(tab.hasEdits ? "Commit" : "Refresh",
                      systemImage: tab.hasEdits ? "checkmark" : "arrow.clockwise")
            }
            .buttonStyle(.glassPillProminent)
            .disabled(model.status == .connecting || tab.isRunning || tab.session == nil)

            if tab.isEditable {
                Button {
                    model.addInsertRow(tab)
                } label: {
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
                .frame(width: 260, height: 24)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))

            sortMenu(tab)
            limitField(tab)
            explainMenu
            autoRefreshMenu(tab)

            if tab.isRunning { ProgressView().controlSize(.mini) }
            Spacer()
            savedQueriesMenu
            Button {
                showingHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.glassPill)
        }
        .padding(6)
    }

    /// EXPLAIN / EXPLAIN ANALYZE for the current statement.
    var explainMenu: some View {
        Menu {
            Button("Explain") { onExplain(false) }
            // Hidden where the dialect has no separate analyzing form (SQLite) —
            // it would silently produce the same plan as plain Explain.
            if let dialect = model.activeTab?.session?.engine.dialect,
               dialect.explainPrefix(analyze: true).prefix != dialect.explainPrefix(analyze: false).prefix {
                Button("Explain Analyze") { onExplain(true) }
            }
        } label: {
            Label("Explain", systemImage: "list.bullet.indent")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .pillChrome()
        .disabled(model.activeTab?.session == nil || model.activeTab?.isRunning == true)
        .help("Show the query plan (Analyze also executes the statement)")
    }

    /// Automatic re-run cadence for this tab; the timer icon tints when active.
    func autoRefreshMenu(_ tab: QueryTab) -> some View {
        Menu {
            Button {
                model.setAutoRefresh(tab, interval: nil)
            } label: {
                if tab.autoRefreshInterval == nil { Label("Off", systemImage: "checkmark") }
                else { Text("Off") }
            }
            Divider()
            ForEach([2.0, 5, 10, 30, 60], id: \.self) { seconds in
                Button {
                    model.setAutoRefresh(tab, interval: seconds)
                } label: {
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .pillChrome()
        .foregroundStyle(tab.autoRefreshInterval != nil ? Color.accentColor : Color.secondary)
        .help("Re-run this query automatically")
    }

    /// Plain, non-localized interval labels ("5 s", "1 min").
    static func intervalLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "1 min"
    }

    /// Column sort picker for a data view (mirrors header-click sorting).
    func sortMenu(_ tab: QueryTab) -> some View {
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
        .pillChrome()
        .help("Sort by a column")
    }

    /// Editable row limit for a data view, overriding the paging default.
    func limitField(_ tab: QueryTab) -> some View {
        HStack(spacing: 3) {
            Text("Limit").font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { tab.pageLimit },
                set: { tab.pageLimit = max(1, $0) }
            ), format: .number)
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: 64)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
            .onSubmit { Task { await model.setLimit(tab, tab.pageLimit) } }
        }
    }

    /// The data view's generated query, shown read-only (highlighted, selectable)
    /// so it's always visible like the console editor but can't be edited.
    func dataSQLView(_ tab: QueryTab) -> some View {
        SQLEditor(text: .constant(tab.sql), schema: nil, focusTrigger: 0, cursor: nil, readOnly: true)
            .frame(height: 52)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}
