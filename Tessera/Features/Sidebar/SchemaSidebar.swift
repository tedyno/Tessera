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
    /// The tree is the cached copy of a disconnected session — flagged in the
    /// header so stale metadata never masquerades as live.
    var isCached: Bool = false
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
    var onOpenDiagram: (_ schema: String) -> Void = { _ in }
    var onShowTableInDiagram: (_ schema: String, _ table: String) -> Void = { _, _ in }
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
    /// Relay tokens: ↑/↓ and Return typed in the search field drive the tree.
    @State private var keyboardStepToken = 0
    @State private var keyboardStep = 0
    @State private var keyboardCommitToken = 0
    /// Current match position/count reported by the speed search.
    @State private var matchPosition = 0
    @State private var matchCount = 0

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
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if isCached {
                            Label("Cached", systemImage: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Showing the last-known schema — connect to refresh")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    SchemaOutlineView(
                        tree: tree,
                        hiddenSchemas: hiddenSchemas,
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
                        onOpenDiagram: onOpenDiagram,
                        onShowTableInDiagram: onShowTableInDiagram,
                        onDDL: onDDL,
                        // The speed search and the bottom field are one thing:
                        // tree-typed characters surface in the field, field
                        // edits retarget the search — matches are jumped to
                        // and tinted, never filtered out.
                        onSpeedSearch: { term, position, count in
                            if searchText != term { searchText = term }
                            matchPosition = position
                            matchCount = count
                        },
                        searchTerm: searchText,
                        onFilterCommit: { openFirstMatch() },
                        keyboardStepToken: keyboardStepToken,
                        keyboardStep: keyboardStep,
                        keyboardCommitToken: keyboardCommitToken,
                        onRevealHandled: onRevealHandled)
                }
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
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    // The field drives the tree: ↑/↓ walk the matched tables
                    // and Return opens the picked row (or the first match) —
                    // connect → type → arrows → Enter, no mouse needed.
                    .onKeyPress(.downArrow) {
                        keyboardStep = 1
                        keyboardStepToken += 1
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        keyboardStep = -1
                        keyboardStepToken += 1
                        return .handled
                    }
                    .onSubmit { keyboardCommitToken += 1 }
                if !searchText.isEmpty {
                    Text(verbatim: "\(matchPosition)/\(matchCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(matchCount == 0 ? AnyShapeStyle(.red)
                                                         : AnyShapeStyle(.secondary))
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
        .background(.ultraThinMaterial)
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

