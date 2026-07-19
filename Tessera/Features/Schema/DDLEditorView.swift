import SwiftUI
import DBKit

/// A structural change the user asked for from the schema tree.
enum DDLOperation: Identifiable {
    case addColumn(schema: String?, table: String)
    case renameColumn(schema: String?, table: String, column: String)
    case changeColumnType(schema: String?, table: String, column: String, currentType: String)
    case setNullability(schema: String?, table: String, column: String, type: String, makeNullable: Bool)
    case dropColumn(schema: String?, table: String, column: String)
    case createIndex(schema: String?, table: String, columns: [String])
    case dropIndex(schema: String?, table: String, index: String)
    case createTable(schema: String?)
    case renameTable(schema: String?, table: String)
    case dropTable(schema: String?, table: String)
    case truncateTable(schema: String?, table: String)

    var id: String { title + (table ?? "") + (column ?? "") }

    var table: String? {
        switch self {
        case .addColumn(_, let t), .renameColumn(_, let t, _), .changeColumnType(_, let t, _, _),
             .setNullability(_, let t, _, _, _), .dropColumn(_, let t, _), .createIndex(_, let t, _),
             .dropIndex(_, let t, _), .renameTable(_, let t), .dropTable(_, let t), .truncateTable(_, let t):
            t
        case .createTable: nil
        }
    }

    var column: String? {
        switch self {
        case .renameColumn(_, _, let c), .changeColumnType(_, _, let c, _),
             .setNullability(_, _, let c, _, _), .dropColumn(_, _, let c): c
        case .dropIndex(_, _, let index): index
        default: nil
        }
    }

    var schema: String? {
        switch self {
        case .addColumn(let s, _), .renameColumn(let s, _, _), .changeColumnType(let s, _, _, _),
             .setNullability(let s, _, _, _, _), .dropColumn(let s, _, _), .createIndex(let s, _, _),
             .dropIndex(let s, _, _), .createTable(let s), .renameTable(let s, _),
             .dropTable(let s, _), .truncateTable(let s, _):
            s
        }
    }

    var title: String {
        switch self {
        case .addColumn: "Add Column"
        case .renameColumn: "Rename Column"
        case .changeColumnType: "Change Column Type"
        case .setNullability(_, _, _, _, let makeNullable): makeNullable ? "Allow NULL" : "Require NOT NULL"
        case .dropColumn: "Drop Column"
        case .createIndex: "Create Index"
        case .dropIndex: "Drop Index"
        case .createTable: "Create Table"
        case .renameTable: "Rename Table"
        case .dropTable: "Drop Table"
        case .truncateTable: "Truncate Table"
        }
    }

    /// Destructive operations get a red confirm button and a warning.
    var isDestructive: Bool {
        switch self {
        case .dropColumn, .dropIndex, .dropTable, .truncateTable: true
        default: false
        }
    }
}

/// Sheet that collects the inputs for a schema change, previews the generated DDL,
/// and applies it.
struct DDLEditorView: View {
    let operation: DDLOperation
    let engine: DatabaseKind
    var onRun: (String) async -> String?     // returns an error message, nil on success
    var onClose: () -> Void

    @State private var name = ""
    @State private var dataType = ""
    @State private var isNullable = true
    @State private var defaultValue = ""
    @State private var unique = false
    @State private var columnsText = ""
    @State private var newColumns: [SchemaDDL.ColumnSpec] = [
        SchemaDDL.ColumnSpec(name: "id", dataType: "serial", isNullable: false),
    ]
    @State private var primaryKey = "id"
    @State private var running = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(operation.title).font(.headline)
            if let table = operation.table {
                Text(SchemaDDL.qualified(schema: operation.schema, table: table, for: engine))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }

            inputs

            VStack(alignment: .leading, spacing: 4) {
                Text("SQL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    Text(generatedSQL.isEmpty ? "—" : generatedSQL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 70)
                .padding(6)
                .background(.quaternary.opacity(0.4))
            }

            if operation.isDestructive {
                Label("This cannot be undone.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { onClose() }
                Button(operation.isDestructive ? "Drop" : "Apply", role: operation.isDestructive ? .destructive : nil) {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(generatedSQL.isEmpty || running)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: prefill)
    }

    // MARK: Inputs per operation

    @ViewBuilder private var inputs: some View {
        switch operation {
        case .addColumn:
            Form {
                TextField("Column name", text: $name)
                TextField("Type (e.g. text, integer)", text: $dataType)
                TextField("Default (optional)", text: $defaultValue)
                Toggle("Allow NULL", isOn: $isNullable)
            }
            .formStyle(.columns)
        case .renameColumn, .renameTable:
            Form { TextField("New name", text: $name) }.formStyle(.columns)
        case .changeColumnType:
            Form { TextField("New type", text: $dataType) }.formStyle(.columns)
        case .createIndex:
            Form {
                TextField("Index name", text: $name)
                TextField("Columns (comma-separated)", text: $columnsText)
                Toggle("Unique", isOn: $unique)
            }
            .formStyle(.columns)
        case .createTable:
            createTableInputs
        case .setNullability, .dropColumn, .dropIndex, .dropTable, .truncateTable:
            EmptyView()
        }
    }

    private var createTableInputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                TextField("Table name", text: $name)
                TextField("Primary key columns (comma-separated)", text: $primaryKey)
            }
            .formStyle(.columns)

            ForEach(newColumns.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("name", text: Binding(
                        get: { newColumns[index].name },
                        set: { newColumns[index].name = $0 }))
                    TextField("type", text: Binding(
                        get: { newColumns[index].dataType },
                        set: { newColumns[index].dataType = $0 }))
                    Toggle("NULL", isOn: Binding(
                        get: { newColumns[index].isNullable },
                        set: { newColumns[index].isNullable = $0 }))
                    .fixedSize()
                    Button {
                        newColumns.remove(at: index)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(newColumns.count <= 1)
                }
            }
            Button("Add column") {
                newColumns.append(SchemaDDL.ColumnSpec(name: "", dataType: "text"))
            }
            .controlSize(.small)
        }
    }

    // MARK: SQL

    private var generatedSQL: String {
        let schema = operation.schema
        switch operation {
        case .addColumn(_, let table):
            guard !name.isEmpty, !dataType.isEmpty else { return "" }
            let spec = SchemaDDL.ColumnSpec(name: name, dataType: dataType, isNullable: isNullable,
                                            defaultValue: defaultValue.isEmpty ? nil : defaultValue)
            return SchemaDDL.addColumn(spec, schema: schema, table: table, for: engine)
        case .renameColumn(_, let table, let column):
            guard !name.isEmpty else { return "" }
            return SchemaDDL.renameColumn(from: column, to: name, schema: schema, table: table, for: engine)
        case .changeColumnType(_, let table, let column, _):
            guard !dataType.isEmpty else { return "" }
            let spec = SchemaDDL.ColumnSpec(name: column, dataType: dataType)
            return SchemaDDL.changeColumnType(spec, schema: schema, table: table, for: engine)
        case .setNullability(_, let table, let column, let type, let makeNullable):
            return SchemaDDL.setColumnNullability(column, isNullable: makeNullable, dataType: type,
                                                  schema: schema, table: table, for: engine)
        case .dropColumn(_, let table, let column):
            return SchemaDDL.dropColumn(column, schema: schema, table: table, for: engine)
        case .createIndex(_, let table, _):
            let columns = splitList(columnsText)
            guard !name.isEmpty, !columns.isEmpty else { return "" }
            return SchemaDDL.createIndex(name: name, columns: columns, unique: unique,
                                         schema: schema, table: table, for: engine)
        case .dropIndex(_, let table, let index):
            return SchemaDDL.dropIndex(name: index, schema: schema, table: table, for: engine)
        case .createTable:
            let columns = newColumns.filter { !$0.name.isEmpty && !$0.dataType.isEmpty }
            guard !name.isEmpty, !columns.isEmpty else { return "" }
            return SchemaDDL.createTable(name: name, schema: schema, columns: columns,
                                         primaryKey: splitList(primaryKey), for: engine)
        case .renameTable(_, let table):
            guard !name.isEmpty else { return "" }
            return SchemaDDL.renameTable(from: table, to: name, schema: schema, for: engine)
        case .dropTable(_, let table):
            return SchemaDDL.dropTable(name: table, schema: schema, ifExists: true, for: engine)
        case .truncateTable(_, let table):
            return SchemaDDL.truncateTable(name: table, schema: schema, for: engine)
        }
    }

    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func prefill() {
        switch operation {
        case .renameColumn(_, _, let column): name = column
        case .renameTable(_, let table): name = table
        case .changeColumnType(_, _, _, let currentType): dataType = currentType
        case .createIndex(_, let table, let columns):
            columnsText = columns.joined(separator: ", ")
            name = "idx_\(table)_\(columns.joined(separator: "_"))"
        default: break
        }
    }

    private func apply() {
        let sql = generatedSQL
        guard !sql.isEmpty else { return }
        running = true
        errorMessage = nil
        Task {
            let failure = await onRun(sql)
            running = false
            if let failure { errorMessage = failure } else { onClose() }
        }
    }
}
