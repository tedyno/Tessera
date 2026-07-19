import SwiftUI
import DBKit

/// Column 2 — the schema of the active connection (Database → Schema → Table →
/// Column), fetched live after connecting. Double-clicking a table runs
/// `SELECT *` via `onOpenTable`.
struct SchemaSidebar: View {
    let tree: DatabaseTree?
    var onOpenTable: (_ schema: String, _ table: String) -> Void
    var onOpenColumn: (_ schema: String, _ table: String, _ column: String) -> Void

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
        if table.columns.isEmpty && table.indexes.isEmpty {
            tableLabel(namespace: namespace, table: table)
        } else {
            DisclosureGroup {
                ForEach(table.columns) { column in
                    columnRow(column)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            onOpenColumn(namespace, table.name, column.name)
                        })
                }
                if !table.indexes.isEmpty {
                    DisclosureGroup {
                        ForEach(table.indexes) { index in indexRow(index) }
                    } label: {
                        Label("Indexes", systemImage: "number")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                tableLabel(namespace: namespace, table: table)
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

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
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
