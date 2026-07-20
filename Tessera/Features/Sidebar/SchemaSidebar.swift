import SwiftUI
import DBKit

/// A target the schema tree should expand to and highlight (from spotlight).
struct SchemaRevealTarget: Equatable {
    var schema: String
    var table: String?
    var column: String?
}

/// Column 2 — the schema of the active connection (Database → Schema → Table →
/// Column), fetched live. Double-clicking a table/column runs `SELECT *`; a
/// `reveal` target (from spotlight) expands and scrolls to the chosen item.
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

    @State private var expanded: Set<String> = ["db"]
    /// Schemas are expanded by default, so this tracks the ones a user explicitly
    /// collapsed instead — an "opt out" set, unlike `expanded`'s "opt in".
    @State private var collapsedSchemas: Set<String> = []
    @State private var highlightedID: String?
    @State private var showingFilter = false
    @State private var searchText = ""

    /// Lowercased, trimmed name filter; empty means "show everything".
    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

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

    private func namespaceMatches(_ namespace: SchemaNamespace) -> Bool {
        guard !query.isEmpty else { return true }
        if namespace.name.lowercased().contains(query) { return true }
        return namespace.tables.contains(where: tableMatches)
    }

    var body: some View {
        Group {
            if let tree {
                ScrollViewReader { proxy in
                    List {
                        Section(connectionName ?? String(localized: "Schema")) {
                            DisclosureGroup(isExpanded: binding("db")) {
                                ForEach(tree.schemas.filter {
                                    !hiddenSchemas.contains($0.name) && namespaceMatches($0)
                                }) { namespace in
                                    schemaNode(namespace)
                                }
                            } label: {
                                Label(tree.databaseName, systemImage: "cylinder.split.1x2")
                                    .foregroundStyle(.tint)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        if databases.count > 1 {
                                            Menu("Switch Database") {
                                                ForEach(databases, id: \.self) { database in
                                                    Button {
                                                        onSwitchDatabase(database)
                                                    } label: {
                                                        if database == tree.databaseName {
                                                            Label(database, systemImage: "checkmark")
                                                        } else {
                                                            Text(database)
                                                        }
                                                    }
                                                }
                                            }
                                            Divider()
                                        }
                                        Button("New Query Tab") { onNewQueryTab() }
                                            .keyboardShortcut("t", modifiers: .command)
                                        Divider()
                                        Button("Dump Database…") { onDumpDatabase() }
                                    }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: reveal) { _, target in
                        if let target { applyReveal(target, proxy: proxy) }
                    }
                }
                .safeAreaInset(edge: .bottom) { filterBar(tree) }
            } else if status == .connecting {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if status == .ready {
                // Connected, but the schema fetch (a separate round trip after the
                // driver connects) hasn't come back yet.
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading schema…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No schema", systemImage: "cylinder.split.1x2",
                                       description: Text("Connect to a database to browse its schema."))
            }
        }
    }

    // MARK: Nodes

    private func schemaNode(_ namespace: SchemaNamespace) -> some View {
        DisclosureGroup(isExpanded: schemaBinding("s:\(namespace.name)")) {
            ForEach(namespace.tables.filter(tableMatches)) { table in
                tableNode(namespace: namespace.name, table: table)
            }
        } label: {
            Label(namespace.name, systemImage: "circle.grid.2x2")
                .id("s:\(namespace.name)")
                .modifier(HighlightRow(active: highlightedID == "s:\(namespace.name)"))
                .contentShape(Rectangle())
                .contextMenu {
                    Button("New Query Tab") { onNewQueryTab() }
                        .keyboardShortcut("t", modifiers: .command)
                    Divider()
                    Button("Create Table…") { onDDL(.createTable(schema: namespace.name)) }
                    Divider()
                    Button("Dump Schema…") { onDumpSchema(namespace.name) }
                }
        }
    }

    @ViewBuilder
    private func tableNode(namespace: String, table: SchemaTable) -> some View {
        let tableKey = "t:\(namespace).\(table.name)"
        if table.columns.isEmpty && table.indexes.isEmpty {
            tableLabel(namespace: namespace, table: table).id(tableKey)
        } else {
            DisclosureGroup(isExpanded: binding(tableKey)) {
                ForEach(table.columns) { column in
                    columnRow(column)
                        .id("c:\(namespace).\(table.name).\(column.name)")
                        .modifier(HighlightRow(active: highlightedID == "c:\(namespace).\(table.name).\(column.name)"))
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            onOpenColumn(namespace, table.name, column.name)
                        })
                        .contextMenu {
                            Button("Rename Column…") {
                                onDDL(.renameColumn(schema: namespace, table: table.name, column: column.name))
                            }
                            Button("Change Type…") {
                                onDDL(.changeColumnType(schema: namespace, table: table.name,
                                                        column: column.name, currentType: column.dataType))
                            }
                            Button(column.isNullable ? "Require NOT NULL" : "Allow NULL") {
                                onDDL(.setNullability(schema: namespace, table: table.name,
                                                      column: column.name, type: column.dataType,
                                                      makeNullable: !column.isNullable))
                            }
                            Divider()
                            Button("Drop Column…", role: .destructive) {
                                onDDL(.dropColumn(schema: namespace, table: table.name, column: column.name))
                            }
                        }
                }
                if !table.indexes.isEmpty {
                    DisclosureGroup {
                        ForEach(table.indexes) { index in
                            indexRow(index)
                                .contextMenu {
                                    Button("Drop Index…", role: .destructive) {
                                        onDDL(.dropIndex(schema: namespace, table: table.name, index: index.name))
                                    }
                                }
                        }
                    } label: {
                        Label("Indexes", systemImage: "number").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } label: {
                tableLabel(namespace: namespace, table: table)
                    .id(tableKey)
                    .modifier(HighlightRow(active: highlightedID == tableKey))
            }
        }
    }

    private func columnRow(_ column: SchemaColumn) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(column.isPrimaryKey ? Color.yellow
                      : (column.isForeignKey ? Color.purple : Color.secondary))
                .frame(width: 6, height: 6)
            Text(column.name)
            if column.isPrimaryKey { badge("PK", .orange) }
            if column.isForeignKey { badge("FK", .purple) }
            if !column.isNullable { badge("NOT NULL", .gray) }
            Spacer(minLength: 8)
            Text(column.dataType)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func indexRow(_ index: SchemaIndex) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "number.square").font(.caption2).foregroundStyle(.secondary)
            Text(index.name)
            if index.isUnique { badge("UNIQUE", .blue) }
            Spacer(minLength: 8)
            Text(index.columns.joined(separator: ", "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func tableLabel(namespace: String, table: SchemaTable) -> some View {
        Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
            .foregroundStyle(table.kind == .view ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpenTable(namespace, table.name) })
            .help("Double-click to SELECT *")
            .contextMenu {
                Button("Open") { onOpenTable(namespace, table.name) }
                Divider()
                Button("Add Column…") { onDDL(.addColumn(schema: namespace, table: table.name)) }
                Button("Create Index…") {
                    onDDL(.createIndex(schema: namespace, table: table.name, columns: []))
                }
                Button("Rename Table…") { onDDL(.renameTable(schema: namespace, table: table.name)) }
                Divider()
                Button("Truncate Table…", role: .destructive) {
                    onDDL(.truncateTable(schema: namespace, table: table.name))
                }
                Button("Drop Table…", role: .destructive) {
                    onDDL(.dropTable(schema: namespace, table: table.name))
                }
                Divider()
                Button("Dump Table…") { onDumpTable(namespace, table.name) }
            }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Expansion + reveal

    private func binding(_ key: String) -> Binding<Bool> {
        // While filtering, force every branch open so matches are visible.
        Binding(get: { expanded.contains(key) || !query.isEmpty },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    /// Schema nodes, unlike DB/table nodes, start expanded — this only tracks the
    /// ones a user collapsed by hand.
    private func schemaBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsedSchemas.contains(key) || !query.isEmpty },
                set: { if $0 { collapsedSchemas.remove(key) } else { collapsedSchemas.insert(key) } })
    }

    private func applyReveal(_ target: SchemaRevealTarget, proxy: ScrollViewProxy) {
        expanded.insert("db")
        collapsedSchemas.remove("s:\(target.schema)")
        let id: String
        if let column = target.column, let table = target.table {
            expanded.insert("t:\(target.schema).\(table)")
            id = "c:\(target.schema).\(table).\(column)"
        } else if let table = target.table {
            id = "t:\(target.schema).\(table)"
        } else {
            id = "s:\(target.schema)"
        }
        highlightedID = id
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if highlightedID == id { highlightedID = nil }
        }
    }

    // MARK: Filter

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

/// Briefly tints a revealed row.
private struct HighlightRow: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.listRowBackground(active ? Color.accentColor.opacity(0.25) : Color.clear)
    }
}
