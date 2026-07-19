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
    var onToggleSchema: (String) -> Void = { _ in }
    var onOpenTable: (_ schema: String, _ table: String) -> Void
    var onOpenColumn: (_ schema: String, _ table: String, _ column: String) -> Void
    var onDumpTable: (_ schema: String, _ table: String) -> Void = { _, _ in }

    @State private var expanded: Set<String> = ["db"]
    @State private var highlightedID: String?
    @State private var showingFilter = false

    var body: some View {
        Group {
            if let tree {
                ScrollViewReader { proxy in
                    List {
                        Section("Schema") {
                            DisclosureGroup(isExpanded: binding("db")) {
                                ForEach(tree.schemas.filter { !hiddenSchemas.contains($0.name) }) { namespace in
                                    schemaNode(namespace)
                                }
                            } label: {
                                Label(tree.databaseName, systemImage: "cylinder.split.1x2")
                                    .foregroundStyle(.tint)
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { toggle("db") })
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: reveal) { _, target in
                        if let target { applyReveal(target, proxy: proxy) }
                    }
                }
                .safeAreaInset(edge: .bottom) { filterBar(tree) }
            } else {
                ContentUnavailableView("No schema", systemImage: "cylinder.split.1x2",
                                       description: Text("Connect to a database to browse its schema."))
            }
        }
    }

    // MARK: Nodes

    private func schemaNode(_ namespace: SchemaNamespace) -> some View {
        DisclosureGroup(isExpanded: binding("s:\(namespace.name)")) {
            ForEach(namespace.tables) { table in
                tableNode(namespace: namespace.name, table: table)
            }
        } label: {
            Label(namespace.name, systemImage: "circle.grid.2x2")
                .id("s:\(namespace.name)")
                .modifier(HighlightRow(active: highlightedID == "s:\(namespace.name)"))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggle("s:\(namespace.name)") })
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
                }
                if !table.indexes.isEmpty {
                    DisclosureGroup {
                        ForEach(table.indexes) { index in indexRow(index) }
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
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    /// Double-click on a container node (database or schema) expands/collapses it.
    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func applyReveal(_ target: SchemaRevealTarget, proxy: ScrollViewProxy) {
        expanded.insert("db")
        expanded.insert("s:\(target.schema)")
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
