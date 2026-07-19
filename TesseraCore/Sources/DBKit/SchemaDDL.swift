import Foundation

/// Generates DDL for schema edits (add/rename/drop columns, indexes, tables).
/// Pure and unit-tested; identifiers are quoted per engine so mixed-case and
/// reserved names survive.
public enum SchemaDDL {

    /// Quotes an identifier: backticks for MySQL, double quotes elsewhere.
    public static func quote(_ identifier: String, for engine: DatabaseKind) -> String {
        switch engine {
        case .mysql: "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres: "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// `schema.table`, or just the table when no schema applies (MySQL).
    public static func qualified(schema: String?, table: String, for engine: DatabaseKind) -> String {
        guard let schema, !schema.isEmpty, engine == .postgres else { return quote(table, for: engine) }
        return "\(quote(schema, for: engine)).\(quote(table, for: engine))"
    }

    // MARK: Columns

    public struct ColumnSpec: Sendable, Equatable {
        public var name: String
        public var dataType: String
        public var isNullable: Bool
        public var defaultValue: String?

        public init(name: String, dataType: String, isNullable: Bool = true, defaultValue: String? = nil) {
            self.name = name
            self.dataType = dataType
            self.isNullable = isNullable
            self.defaultValue = defaultValue
        }

        /// The `name type [DEFAULT x] [NOT NULL]` fragment used in CREATE/ADD.
        func definition(for engine: DatabaseKind) -> String {
            var parts = [SchemaDDL.quote(name, for: engine), dataType]
            if let defaultValue, !defaultValue.isEmpty { parts.append("DEFAULT \(defaultValue)") }
            if !isNullable { parts.append("NOT NULL") }
            return parts.joined(separator: " ")
        }
    }

    public static func addColumn(_ column: ColumnSpec, schema: String?, table: String,
                                 for engine: DatabaseKind) -> String {
        "ALTER TABLE \(qualified(schema: schema, table: table, for: engine)) "
            + "ADD COLUMN \(column.definition(for: engine));"
    }

    public static func dropColumn(_ name: String, schema: String?, table: String,
                                  for engine: DatabaseKind) -> String {
        "ALTER TABLE \(qualified(schema: schema, table: table, for: engine)) "
            + "DROP COLUMN \(quote(name, for: engine));"
    }

    public static func renameColumn(from oldName: String, to newName: String, schema: String?,
                                    table: String, for engine: DatabaseKind) -> String {
        "ALTER TABLE \(qualified(schema: schema, table: table, for: engine)) "
            + "RENAME COLUMN \(quote(oldName, for: engine)) TO \(quote(newName, for: engine));"
    }

    /// Changing a column's type differs per engine: Postgres uses ALTER COLUMN …
    /// TYPE, MySQL redefines the whole column with MODIFY.
    public static func changeColumnType(_ column: ColumnSpec, schema: String?, table: String,
                                        for engine: DatabaseKind) -> String {
        let target = qualified(schema: schema, table: table, for: engine)
        switch engine {
        case .postgres:
            return "ALTER TABLE \(target) ALTER COLUMN \(quote(column.name, for: engine)) "
                + "TYPE \(column.dataType);"
        case .mysql:
            return "ALTER TABLE \(target) MODIFY COLUMN \(column.definition(for: engine));"
        }
    }

    public static func setColumnNullability(_ name: String, isNullable: Bool, dataType: String,
                                            schema: String?, table: String,
                                            for engine: DatabaseKind) -> String {
        let target = qualified(schema: schema, table: table, for: engine)
        switch engine {
        case .postgres:
            let action = isNullable ? "DROP NOT NULL" : "SET NOT NULL"
            return "ALTER TABLE \(target) ALTER COLUMN \(quote(name, for: engine)) \(action);"
        case .mysql:
            let spec = ColumnSpec(name: name, dataType: dataType, isNullable: isNullable)
            return "ALTER TABLE \(target) MODIFY COLUMN \(spec.definition(for: engine));"
        }
    }

    // MARK: Indexes

    public static func createIndex(name: String, columns: [String], unique: Bool,
                                   schema: String?, table: String, for engine: DatabaseKind) -> String {
        let columnList = columns.map { quote($0, for: engine) }.joined(separator: ", ")
        return "CREATE \(unique ? "UNIQUE " : "")INDEX \(quote(name, for: engine)) "
            + "ON \(qualified(schema: schema, table: table, for: engine)) (\(columnList));"
    }

    /// MySQL drops indexes through ALTER TABLE; Postgres drops them by name.
    public static func dropIndex(name: String, schema: String?, table: String,
                                 for engine: DatabaseKind) -> String {
        switch engine {
        case .postgres:
            let qualifiedIndex = (schema?.isEmpty == false)
                ? "\(quote(schema!, for: engine)).\(quote(name, for: engine))"
                : quote(name, for: engine)
            return "DROP INDEX \(qualifiedIndex);"
        case .mysql:
            return "ALTER TABLE \(qualified(schema: schema, table: table, for: engine)) "
                + "DROP INDEX \(quote(name, for: engine));"
        }
    }

    // MARK: Tables

    public static func createTable(name: String, schema: String?, columns: [ColumnSpec],
                                   primaryKey: [String], for engine: DatabaseKind) -> String {
        var definitions = columns.map { $0.definition(for: engine) }
        if !primaryKey.isEmpty {
            let keys = primaryKey.map { quote($0, for: engine) }.joined(separator: ", ")
            definitions.append("PRIMARY KEY (\(keys))")
        }
        let body = definitions.joined(separator: ",\n    ")
        return "CREATE TABLE \(qualified(schema: schema, table: name, for: engine)) (\n    \(body)\n);"
    }

    public static func dropTable(name: String, schema: String?, ifExists: Bool,
                                 for engine: DatabaseKind) -> String {
        "DROP TABLE \(ifExists ? "IF EXISTS " : "")"
            + "\(qualified(schema: schema, table: name, for: engine));"
    }

    public static func renameTable(from oldName: String, to newName: String, schema: String?,
                                   for engine: DatabaseKind) -> String {
        let target = qualified(schema: schema, table: oldName, for: engine)
        switch engine {
        case .postgres:
            return "ALTER TABLE \(target) RENAME TO \(quote(newName, for: engine));"
        case .mysql:
            return "RENAME TABLE \(target) TO \(quote(newName, for: engine));"
        }
    }

    public static func truncateTable(name: String, schema: String?, for engine: DatabaseKind) -> String {
        "TRUNCATE TABLE \(qualified(schema: schema, table: name, for: engine));"
    }
}
