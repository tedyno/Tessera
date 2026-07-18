import SwiftUI
import DBKit

/// Column 2 — the schema of the active connection (Database → Schema → Table →
/// Column), fetched live after connecting. Double-clicking a table runs
/// `SELECT *` via `onOpenTable`.
struct SchemaSidebar: View {
    let tree: DatabaseTree?
    var onOpenTable: (_ schema: String, _ table: String) -> Void

    var body: some View {
        Group {
            if let tree {
                List {
                    Section("Schema") {
                        DisclosureGroup {
                            ForEach(tree.schemas) { namespace in
                                DisclosureGroup {
                                    ForEach(namespace.tables) { table in
                                        tableNode(namespace: namespace.name, table: table)
                                    }
                                } label: {
                                    Label(namespace.name, systemImage: "circle.grid.2x2")
                                }
                            }
                        } label: {
                            Label(tree.databaseName, systemImage: "cylinder.split.1x2")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView("No schema", systemImage: "cylinder.split.1x2",
                                       description: Text("Connect to a database to browse its schema."))
            }
        }
    }

    @ViewBuilder
    private func tableNode(namespace: String, table: SchemaTable) -> some View {
        if table.columns.isEmpty {
            tableLabel(namespace: namespace, table: table)
        } else {
            DisclosureGroup {
                ForEach(table.columns) { column in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(column.isPrimaryKey ? Color.yellow : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(column.name)
                        Spacer(minLength: 8)
                        Text(column.dataType)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                tableLabel(namespace: namespace, table: table)
            }
        }
    }

    private func tableLabel(namespace: String, table: SchemaTable) -> some View {
        Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
            .foregroundStyle(table.kind == .view ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onOpenTable(namespace, table.name) }
            )
            .help("Double-click to SELECT *")
    }
}
