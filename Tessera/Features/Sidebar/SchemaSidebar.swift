import SwiftUI
import DBKit

/// A target the schema tree should expand to and highlight (from spotlight).
struct SchemaRevealTarget: Equatable {
    var schema: String
    var table: String?
    var column: String?
}

private extension View {
    /// Pointing-hand cursor on hover — SwiftUI gives row content no cursor feedback
    /// on macOS by default, so a double-clickable row looked no different from plain
    /// text.
    func pointerCursor() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    /// Full-row hit target: a bare Label only takes clicks on its icon and text,
    /// leaving dead zones to the right of the name and in the row padding.
    func rowHitTarget() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
    }
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
    /// Engine of the active connection — gates DDL items the dialect can't express
    /// (SQLite's minimal ALTER) and swaps dumps for Reveal in Finder on files.
    var engine: DatabaseKind?
    /// Shows the SQLite database file in Finder (file-based engines have no dump).
    var onRevealDatabaseFile: () -> Void = { }
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
    /// Opens every table in the list at once (⌘/⇧-click to build the selection,
    /// then double-click or the context menu's "Open N Tables").
    var onOpenTables: (_ tables: [(schema: String, table: String)]) -> Void = { _ in }
    /// Dumps several tables into one file — only offered when they all share a
    /// schema, since a dump target is scoped to a single schema.
    var onDumpTables: (_ schema: String, _ tables: [String]) -> Void = { _, _ in }
    /// Dumps several schemas into one file. All schemas in the sidebar belong to
    /// the one database shown, so the same-database constraint holds by
    /// construction (one dump = one database connection).
    var onDumpSchemas: (_ schemas: [String]) -> Void = { _ in }

    @State private var expanded: Set<String> = ["db"]
    /// Schemas are expanded by default, so this tracks the ones a user explicitly
    /// collapsed instead — an "opt out" set, unlike `expanded`'s "opt in".
    @State private var collapsedSchemas: Set<String> = []
    @State private var highlightedID: String?
    @State private var showingFilter = false
    @State private var searchText = ""

    private struct TableRef: Hashable { let schema: String; let table: String }
    /// Multi-selected tables (⌘/⇧-click) — scoped to tables only, not schemas/columns:
    /// those have their own distinct actions that don't generalize into a batch.
    @State private var selectedTables: Set<TableRef> = []
    @State private var selectionAnchor: TableRef?
    /// Multi-selected schemas (⌘-click), mutually exclusive with the table
    /// selection — the batch action ("Dump N Schemas…") only makes sense within
    /// the one database the sidebar shows.
    @State private var selectedSchemas: Set<String> = []
    /// Whether the database row itself is highlighted (single, no batch actions).
    @State private var dbSelected = false

    /// PhpStorm-style speed search: with a sidebar row selected, typing jumps to
    /// the first matching schema/table, arrows walk the matches, Esc ends the
    /// search leaving the selection where it landed.
    @State private var speedSearch = ""
    @State private var speedMatchIndex = 0
    @State private var speedMatchCount = 0
    @State private var speedScrollTarget: String?
    @State private var speedKeyMonitor: Any?

    /// Whether the engine's ALTER can express this operation (defaults to yes
    /// while nothing is connected — the menu isn't reachable then anyway).
    private func supports(_ operation: SchemaDDL.Operation) -> Bool {
        engine.map { SchemaDDL.supports(operation, for: $0) } ?? true
    }

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
                                    .listRowBackground(nodeBackground("db"))
                                    .rowHitTarget()
                                    .pointerCursor()
                                    .simultaneousGesture(TapGesture(count: 1).onEnded { selectDatabase() })
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
                                        if engine?.isFileBased == true {
                                            Button("Reveal in Finder") { onRevealDatabaseFile() }
                                        } else {
                                            Button("Dump Database…") { onDumpDatabase() }
                                        }
                                    }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: reveal) { _, target in
                        if let target { applyReveal(target, proxy: proxy) }
                    }
                    // Both, not just the database name: two connections often serve a
                    // database of the same name, and a selection built on one must not
                    // leak into "Open N Tables" against the other.
                    .onChange(of: tree.databaseName) { _, _ in clearTableSelection() }
                    .onChange(of: connectionName) { _, _ in clearTableSelection() }
                    .onChange(of: speedScrollTarget) { _, id in
                        guard let id else { return }
                        // Next runloop turn, after the selection re-render — List
                        // virtualizes rows, and an immediate scrollTo can miss a
                        // target that isn't laid out yet.
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .center)
                            speedScrollTarget = nil
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { filterBar(tree) }
                .safeAreaInset(edge: .top) { speedSearchBar }
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
        .onAppear { installSpeedSearchMonitor() }
        .onDisappear {
            if let monitor = speedKeyMonitor { NSEvent.removeMonitor(monitor) }
            speedKeyMonitor = nil
            speedSearch = ""
        }
    }

    // MARK: Speed search

    /// One row the speed search can land on.
    private enum SpeedTarget: Equatable {
        case schema(String)
        case table(TableRef)

        var name: String {
            switch self {
            case .schema(let name): name
            case .table(let ref): ref.table
            }
        }
        var rowID: String {
            switch self {
            case .schema(let name): "s:\(name)"
            case .table(let ref): "t:\(ref.schema).\(ref.table)"
            }
        }
    }

    /// Schema and table rows in display order, restricted to what's actually on
    /// screen (hidden/collapsed schemas and the name filter are respected).
    private func speedCandidates() -> [SpeedTarget] {
        guard let tree else { return [] }
        var out: [SpeedTarget] = []
        for namespace in tree.schemas where !hiddenSchemas.contains(namespace.name) && namespaceMatches(namespace) {
            out.append(.schema(namespace.name))
            guard !collapsedSchemas.contains("s:\(namespace.name)") || !query.isEmpty else { continue }
            for table in namespace.tables where tableMatches(table) {
                out.append(.table(TableRef(schema: namespace.name, table: table.name)))
            }
        }
        return out
    }

    private func speedMatches() -> [SpeedTarget] {
        let term = speedSearch.lowercased()
        guard !term.isEmpty else { return [] }
        return speedCandidates().filter { $0.name.lowercased().contains(term) }
    }

    private func installSpeedSearchMonitor() {
        guard speedKeyMonitor == nil else { return }
        speedKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleSpeedSearchKey(event) ? nil : event
        }
    }

    /// Returns true when the event was consumed by the speed search.
    private func handleSpeedSearchKey(_ event: NSEvent) -> Bool {
        guard tree != nil, let window = event.window, window.isKeyWindow,
              window.sheetParent == nil, !(window is NSPanel) else { return false }
        // Never steal typing from an editor, a text field or the results grid
        // (the grid starts a cell edit from a plain keystroke). SwiftUI's own
        // List is backed by an NSTableView too, so only non-SwiftUI tables (the
        // grid, the organizer outline) opt out.
        if let responder = window.firstResponder {
            if responder is NSText || responder is NSTextView { return false }
            if responder is NSTableView,
               !String(reflecting: type(of: responder)).hasPrefix("SwiftUI.") {
                return false
            }
        }
        let active = !speedSearch.isEmpty
        // The "context": a sidebar row is selected, or a search is already running.
        guard active || dbSelected || !selectedSchemas.isEmpty || !selectedTables.isEmpty else {
            return false
        }

        switch event.keyCode {
        case 53:   // Esc — end the search; the selection stays where it landed
            guard active else { return false }
            speedSearch = ""
            return true
        case 36, 76:   // Return — same: the match is already selected
            guard active else { return false }
            speedSearch = ""
            return true
        case 51:   // Backspace
            guard active else { return false }
            speedSearch.removeLast()
            if !speedSearch.isEmpty { retargetSpeedSearch() }
            else { speedMatchCount = 0 }
            return true
        case 125, 126:   // ↓ / ↑ — walk the matches, wrapping around
            guard active else { return false }
            let matches = speedMatches()
            speedMatchCount = matches.count
            guard !matches.isEmpty else { return true }
            speedMatchIndex = (speedMatchIndex + (event.keyCode == 125 ? 1 : -1)
                               + matches.count) % matches.count
            selectSpeedTarget(matches[speedMatchIndex])
            return true
        default:
            break
        }

        guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
                || "_$.".unicodeScalars.contains(scalar)
        else { return false }
        speedSearch.append(Character(scalar))
        retargetSpeedSearch()
        return true
    }

    /// Jumps to the best match for the current term: the first prefix match in
    /// display order, or the first substring match when no name starts with it.
    private func retargetSpeedSearch() {
        let matches = speedMatches()
        speedMatchCount = matches.count
        guard !matches.isEmpty else { return }   // keep selection; the bar turns red
        let term = speedSearch.lowercased()
        speedMatchIndex = matches.firstIndex { $0.name.lowercased().hasPrefix(term) } ?? 0
        selectSpeedTarget(matches[speedMatchIndex])
    }

    private func selectSpeedTarget(_ target: SpeedTarget) {
        // No animation: animating the selection tint re-renders every row of a
        // large tree per keystroke, which made the search feel sluggish.
        switch target {
        case .schema(let name):
            selectedTables = []
            selectionAnchor = nil
            dbSelected = false
            selectedSchemas = [name]
        case .table(let ref):
            selectedSchemas = []
            dbSelected = false
            selectedTables = [ref]
            selectionAnchor = ref
        }
        speedScrollTarget = target.rowID
    }

    @ViewBuilder
    private var speedSearchBar: some View {
        if !speedSearch.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: speedSearch)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(speedMatchCount == 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Spacer()
                if speedMatchCount > 0 {
                    Text(verbatim: "\(speedMatchIndex + 1)/\(speedMatchCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
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
                .listRowBackground(nodeBackground("s:\(namespace.name)"))
                .rowHitTarget()
                .pointerCursor()
                .simultaneousGesture(TapGesture(count: 1).onEnded { handleSchemaClick(namespace.name) })
                .contextMenu {
                    // Same rule as tables: right-clicking a schema that's part of a
                    // multi-selection acts on the whole selection.
                    let targets = selectedSchemas.contains(namespace.name) && selectedSchemas.count > 1
                        ? Array(selectedSchemas) : [namespace.name]
    if targets.count > 1 {
                        if engine?.isFileBased != true {
                            Button("Dump \(targets.count) Schemas…") { onDumpSchemas(targets) }
                        }
                    } else {
                        Button("New Query Tab") { onNewQueryTab() }
                            .keyboardShortcut("t", modifiers: .command)
                        Divider()
                        Button("Create Table…") { onDDL(.createTable(schema: namespace.name)) }
                        if engine?.isFileBased != true {
                            Divider()
                            Button("Dump Schema…") { onDumpSchema(namespace.name) }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func tableNode(namespace: String, table: SchemaTable) -> some View {
        let tableKey = "t:\(namespace).\(table.name)"
        if table.columns.isEmpty && table.indexes.isEmpty {
            tableLabel(namespace: namespace, table: table)
                .id(tableKey)
                .listRowBackground(tableBackground(tableKey, namespace: namespace, table: table.name))
        } else {
            DisclosureGroup(isExpanded: binding(tableKey)) {
                ForEach(table.columns) { column in
                    columnRow(column)
                        .id("c:\(namespace).\(table.name).\(column.name)")
                        .modifier(HighlightRow(active: highlightedID == "c:\(namespace).\(table.name).\(column.name)"))
                        .rowHitTarget()
                        .pointerCursor()
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            onOpenColumn(namespace, table.name, column.name)
                        })
                        .contextMenu {
                            Button("Rename Column…") {
                                onDDL(.renameColumn(schema: namespace, table: table.name, column: column.name))
                            }
                            if supports(.changeColumnType) {
                                Button("Change Type…") {
                                    onDDL(.changeColumnType(schema: namespace, table: table.name,
                                                            column: column.name, currentType: column.dataType))
                                }
                            }
                            if supports(.setNullability) {
                                Button(column.isNullable ? "Require NOT NULL" : "Allow NULL") {
                                    onDDL(.setNullability(schema: namespace, table: table.name,
                                                          column: column.name, type: column.dataType,
                                                          makeNullable: !column.isNullable))
                                }
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
                                .rowHitTarget()
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
                    .listRowBackground(tableBackground(tableKey, namespace: namespace, table: table.name))
            }
        }
    }

    /// The revealed-from-spotlight flash takes priority over the persistent
    /// multi-selection tint — the two would otherwise fight over `listRowBackground`.
    private func tableBackground(_ key: String, namespace: String, table: String) -> Color {
        if highlightedID == key { return Color.accentColor.opacity(0.25) }
        if selectedTables.contains(TableRef(schema: namespace, table: table)) { return Color.accentColor.opacity(0.15) }
        return Color.clear
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
        let ref = TableRef(schema: namespace, table: table.name)
        return Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
            .foregroundStyle(table.kind == .view ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .rowHitTarget()
            .pointerCursor()
            // A plain click only selects (⌘/⇧ extend the selection); double-click
            // still opens immediately and collapses the selection to just this table.
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                handleTableClick(namespace: namespace, table: table.name)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                selectedTables = [ref]
                selectionAnchor = ref
                onOpenTable(namespace, table.name)
            })
            .help("Double-click to SELECT *")
            .contextMenu {
                // Right-clicking a table that's already part of a multi-selection
                // operates on the whole selection — matching the organizer's rule.
                let targets = selectedTables.contains(ref) && selectedTables.count > 1
                    ? Array(selectedTables) : [ref]
                if targets.count > 1 {
                    Button("Open \(targets.count) Tables") {
                        onOpenTables(targets.map { (schema: $0.schema, table: $0.table) })
                    }
                    let schemas = Set(targets.map(\.schema))
                    if schemas.count == 1, let schema = schemas.first, engine?.isFileBased != true {
                        Button("Dump \(targets.count) Tables…") {
                            onDumpTables(schema, targets.map(\.table))
                        }
                    }
                } else {
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
                    if engine?.isFileBased != true {
                        Divider()
                        Button("Dump Table…") { onDumpTable(namespace, table.name) }
                    }
                }
            }
    }

    private func clearTableSelection() {
        speedSearch = ""
        withAnimation(.easeOut(duration: 0.15)) {
            selectedTables = []
            selectionAnchor = nil
            selectedSchemas = []
            dbSelected = false
        }
    }

    /// Click on the database row: single highlight, exclusive with everything else.
    private func selectDatabase() {
        clearTableSelection()
        withAnimation(.easeOut(duration: 0.15)) { dbSelected = true }
    }

    /// Click on a schema row: ⌘ toggles it in/out of the schema selection, a plain
    /// click replaces it — mirroring how table clicks behave.
    private func handleSchemaClick(_ name: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            selectedTables = []
            selectionAnchor = nil
            dbSelected = false
            if NSEvent.modifierFlags.contains(.command) {
                if selectedSchemas.contains(name) { selectedSchemas.remove(name) }
                else { selectedSchemas.insert(name) }
            } else {
                selectedSchemas = [name]
            }
        }
    }

    /// The reveal-from-spotlight flash takes priority over the click highlight.
    private func nodeBackground(_ key: String) -> Color {
        if highlightedID == key { return Color.accentColor.opacity(0.25) }
        if key == "db" ? dbSelected : selectedSchemas.contains(String(key.dropFirst(2))) {
            return Color.accentColor.opacity(0.15)
        }
        return Color.clear
    }

    /// ⌘ toggles a table in/out of the selection; ⇧ extends it as a contiguous
    /// range (within the currently expanded/filter-matching tables); a plain click
    /// replaces the selection with just this one table.
    private func handleTableClick(namespace: String, table: String) {
        let ref = TableRef(schema: namespace, table: table)
        let modifiers = NSEvent.modifierFlags
        withAnimation(.easeOut(duration: 0.15)) {
            // A table click takes the highlight from any container row.
            selectedSchemas = []
            dbSelected = false
            if modifiers.contains(.command) {
                if selectedTables.contains(ref) { selectedTables.remove(ref) } else { selectedTables.insert(ref) }
                selectionAnchor = ref
            } else if modifiers.contains(.shift), let anchor = selectionAnchor {
                let order = visibleTableOrder()
                if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: ref) {
                    let range = from <= to ? from...to : to...from
                    selectedTables = Set(order[range])
                } else {
                    selectedTables = [ref]
                    selectionAnchor = ref
                }
            } else {
                selectedTables = [ref]
                selectionAnchor = ref
            }
        }
    }

    /// Tables in display order, restricted to expanded schemas and the current
    /// filter — the range a ⇧-click extends across.
    private func visibleTableOrder() -> [TableRef] {
        guard let tree else { return [] }
        var order: [TableRef] = []
        for namespace in tree.schemas where !hiddenSchemas.contains(namespace.name) && namespaceMatches(namespace) {
            guard !collapsedSchemas.contains("s:\(namespace.name)") || !query.isEmpty else { continue }
            for table in namespace.tables where tableMatches(table) {
                order.append(TableRef(schema: namespace.name, table: table.name))
            }
        }
        return order
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
