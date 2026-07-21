import SwiftUI
import DBKit

/// A target the schema tree should expand to and highlight (from spotlight).
struct SchemaRevealTarget: Equatable {
    var schema: String
    var table: String?
    var column: String?
}

/// Column 2 — the schema of the active connection. The tree itself is a native
/// `NSOutlineView` (`SchemaOutlineView`); this wrapper owns what stays SwiftUI:
/// the connecting/loading/empty states, the speed-search indicator, and the
/// bottom filter bar with the visible-schemas popover.
struct SchemaSidebar: View {
    let tree: DatabaseTree?
    var hiddenSchemas: Set<String> = []
    var reveal: SchemaRevealTarget?
    /// Which connection this tree belongs to. Two connections often share a database
    /// name (a local and a tunnelled `enelink`), so the name alone is ambiguous.
    var connectionName: String?
    /// Distinguishes "still connecting" from "nothing selected" while `tree` is nil —
    /// otherwise a slow connection briefly looks like there's no database at all.
    var status: ConnectionSession.Status = .idle
    /// Engine of the active connection — gates DDL items the dialect can't express
    /// (SQLite's minimal ALTER) and swaps dumps for Reveal in Finder on files.
    var engine: DatabaseKind?
    /// Shows the SQLite database file in Finder (file-based engines have no dump).
    var onRevealDatabaseFile: () -> Void = { }
    /// Called once a spotlight reveal was applied — the owner clears the target.
    var onRevealHandled: () -> Void = { }
    /// Databases on the server, for the database-switcher menu.
    var databases: [String] = []
    var onSwitchDatabase: (String) -> Void = { _ in }
    /// Opens a query tab on this connection (⌘T from the tree).
    var onNewQueryTab: () -> Void = { }
    var onToggleSchema: (String) -> Void = { _ in }
    var onOpenTable: (_ schema: String, _ table: String) -> Void
    var onOpenColumn: (_ schema: String, _ table: String, _ column: String) -> Void
    var onDumpTable: (_ schema: String, _ table: String) -> Void = { _, _ in }
    var onDumpSchema: (_ schema: String) -> Void = { _ in }
    var onDumpDatabase: () -> Void = { }
    var onDDL: (DDLOperation) -> Void = { _ in }
    /// Opens every table in the list at once (multi-selection double-click / ⌘↩).
    var onOpenTables: (_ tables: [(schema: String, table: String)]) -> Void = { _ in }
    /// Dumps several tables into one file — only offered when they all share a
    /// schema, since a dump target is scoped to a single schema.
    var onDumpTables: (_ schema: String, _ tables: [String]) -> Void = { _, _ in }
    /// Dumps several schemas into one file. All schemas in the sidebar belong to
    /// the one database shown, so the same-database constraint holds by
    /// construction (one dump = one database connection).
    var onDumpSchemas: (_ schemas: [String]) -> Void = { _ in }

    @State private var showingFilter = false
    @State private var searchText = ""
    /// Mirror of the outline's speed search, for the indicator bar.
    @State private var speedTerm = ""
    @State private var speedPosition = 0
    @State private var speedCount = 0
    /// Incremented by the bar's ✕ button; the outline cancels when it changes.
    @State private var speedCancelCount = 0

    /// Lowercased, trimmed name filter; empty means "show everything".
    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var body: some View {
        Group {
            if let tree {
                VStack(spacing: 0) {
                    HStack {
                        Text(connectionName ?? String(localized: "Schema"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    SchemaOutlineView(
                        tree: tree,
                        hiddenSchemas: hiddenSchemas,
                        query: query,
                        reveal: reveal,
                        engine: engine,
                        databases: databases,
                        onSwitchDatabase: onSwitchDatabase,
                        onNewQueryTab: onNewQueryTab,
                        onOpenTable: onOpenTable,
                        onOpenColumn: onOpenColumn,
                        onOpenTables: onOpenTables,
                        onDumpTable: onDumpTable,
                        onDumpTables: onDumpTables,
                        onDumpSchema: onDumpSchema,
                        onDumpSchemas: onDumpSchemas,
                        onDumpDatabase: onDumpDatabase,
                        onRevealDatabaseFile: onRevealDatabaseFile,
                        onDDL: onDDL,
                        onSpeedSearch: { term, position, count in
                            speedTerm = term
                            speedPosition = position
                            speedCount = count
                        },
                        onRevealHandled: onRevealHandled,
                        speedCancelToken: speedCancelCount)
                }
                .safeAreaInset(edge: .top) { speedSearchBar }
                .safeAreaInset(edge: .bottom) { filterBar(tree) }
                .transition(.opacity)
            } else if status == .connecting {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if status == .ready {
                // Connected, but the schema fetch (a separate round trip after the
                // driver connects) hasn't come back yet.
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading schema…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                ContentUnavailableView("No schema", systemImage: "cylinder.split.1x2",
                                       description: Text("Connect to a database to browse its schema."))
                    .transition(.opacity)
            }
        }
        // Connecting → loading schema → tree cross-fades instead of hard-swapping.
        .animation(.easeInOut(duration: 0.25), value: status)
        .animation(.easeInOut(duration: 0.25), value: tree == nil)
    }

    // MARK: Speed search indicator

    @ViewBuilder
    private var speedSearchBar: some View {
        if !speedTerm.isEmpty {
            SpeedSearchBar(term: speedTerm, position: speedPosition, count: speedCount,
                           onCancel: { speedCancelCount += 1 })
        }
    }

    // MARK: Filter

    private func tableMatches(_ table: SchemaTable) -> Bool {
        guard !query.isEmpty else { return true }
        if table.name.lowercased().contains(query) { return true }
        return table.columns.contains { $0.name.lowercased().contains(query) }
    }

    /// Opens the first table the filter matches, preferring a hit on the table's own
    /// name over one that only matched a column.
    private func openFirstMatch() {
        guard !query.isEmpty, let tree else { return }
        let visible = tree.schemas.filter { !hiddenSchemas.contains($0.name) }
        for namespace in visible {
            if let table = namespace.tables.first(where: { $0.name.lowercased().contains(query) }) {
                onOpenTable(namespace.name, table.name)
                return
            }
        }
        for namespace in visible {
            if let table = namespace.tables.first(where: tableMatches) {
                onOpenTable(namespace.name, table.name)
                return
            }
        }
    }

    private func filterBar(_ tree: DatabaseTree) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Filter tables & columns", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    // Enter opens the first match, so connect → type → Enter lands
                    // straight in the table without reaching for the mouse.
                    .onSubmit { openFirstMatch() }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button {
                    showingFilter.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .help("Choose visible schemas")
                .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
                    schemaFilterList(tree)
                }
                let shown = tree.schemas.count - tree.schemas.filter { hiddenSchemas.contains($0.name) }.count
                Text("\(shown) of \(tree.schemas.count) schemas")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// A checklist of schemas that stays open across clicks (dismisses on click-away),
    /// so several schemas can be toggled in one pass.
    private func schemaFilterList(_ tree: DatabaseTree) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Visible schemas").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(tree.schemas) { namespace in
                Toggle(isOn: Binding(
                    get: { !hiddenSchemas.contains(namespace.name) },
                    set: { _ in onToggleSchema(namespace.name) }
                )) {
                    Text(namespace.name)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(12)
        .frame(minWidth: 180, alignment: .leading)
    }
}

/// The indicator strip of a tree's speed search — shared by the schema tree and
/// the connection organizer.
struct SpeedSearchBar: View {
    let term: String
    let position: Int
    let count: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: term)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(count == 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Spacer()
            if count > 0 {
                Text(verbatim: "\(position)/\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Cancel search (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
