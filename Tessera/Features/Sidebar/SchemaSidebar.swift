import SwiftUI
import DBKit

/// Column 2 — the schema of the active connection (Database → Schema → Table →
/// Column). Phase 0: a static tree from sample data; in Phase 3 it is filled by
/// a `SchemaProvider` from the live session with lazy branch loading.
struct SchemaSidebar: View {
    let tree: DatabaseTree

    var body: some View {
        List {
            Section("Schema") {
                DisclosureGroup {
                    ForEach(tree.schemas) { namespace in
                        DisclosureGroup {
                            ForEach(namespace.tables) { table in
                                tableNode(table)
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
    }

    @ViewBuilder
    private func tableNode(_ table: SchemaTable) -> some View {
        if table.columns.isEmpty {
            tableLabel(table)
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
                tableLabel(table)
            }
        }
    }

    private func tableLabel(_ table: SchemaTable) -> some View {
        Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
            .foregroundStyle(table.kind == .view ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}
