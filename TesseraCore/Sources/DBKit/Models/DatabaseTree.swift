import Foundation

/// The column a foreign key points at, so the UI can follow the reference.
public struct ForeignKeyTarget: Codable, Sendable, Hashable {
    public var schema: String
    public var table: String
    public var column: String

    public init(schema: String, table: String, column: String) {
        self.schema = schema
        self.table = table
        self.column = column
    }
}

public struct SchemaColumn: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var dataType: String
    public var isPrimaryKey: Bool
    public var isForeignKey: Bool
    public var isNullable: Bool
    /// True for serial/identity (Postgres) or AUTO_INCREMENT (MySQL) columns —
    /// the database supplies the value, so inserts should omit it.
    public var isAutoIncrement: Bool
    /// Where this foreign key points, when known. Only set for single-column keys;
    /// following one composite column alone would filter to the wrong rows.
    public var references: ForeignKeyTarget?

    public var id: String { name }

    public init(name: String, dataType: String, isPrimaryKey: Bool = false,
                isForeignKey: Bool = false, isNullable: Bool = true,
                isAutoIncrement: Bool = false, references: ForeignKeyTarget? = nil) {
        self.name = name
        self.dataType = dataType
        self.isPrimaryKey = isPrimaryKey
        self.isForeignKey = isForeignKey
        self.isNullable = isNullable
        self.isAutoIncrement = isAutoIncrement
        self.references = references
    }
}

/// An index on a table.
public struct SchemaIndex: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool

    public var id: String { name }

    public init(name: String, columns: [String], isUnique: Bool = false) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
    }
}

/// A table or view within a schema.
public struct SchemaTable: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case table
        case view
    }

    public var name: String
    public var kind: Kind
    public var columns: [SchemaColumn]
    public var indexes: [SchemaIndex]
    /// Planner/statistics estimate of the row count, when the engine keeps one —
    /// display only (sidebar badge), never exact. Optional so cached trees from
    /// before this field decode unchanged.
    public var approximateRowCount: Int?

    public var id: String { name }

    public init(name: String, kind: Kind = .table, columns: [SchemaColumn] = [],
                indexes: [SchemaIndex] = [], approximateRowCount: Int? = nil) {
        self.name = name
        self.kind = kind
        self.columns = columns
        self.indexes = indexes
        self.approximateRowCount = approximateRowCount
    }
}

/// A namespace / schema (e.g. `public`, `audit`).
public struct SchemaNamespace: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var tables: [SchemaTable]

    public var id: String { name }

    public init(name: String, tables: [SchemaTable] = []) {
        self.name = name
        self.tables = tables
    }
}

/// Schema tree of a single database (Database → Schema → Table → Column).
/// Produced by introspection after connecting, and cached on disk so search can
/// reach connections that aren't open. Holds names only — never any row data.
public struct DatabaseTree: Codable, Sendable, Hashable {
    public var databaseName: String
    public var schemas: [SchemaNamespace]

    public init(databaseName: String, schemas: [SchemaNamespace] = []) {
        self.databaseName = databaseName
        self.schemas = schemas
    }

    /// Every column in the tree whose foreign key points at the given column —
    /// the reverse of `SchemaColumn.references`, so the UI can offer the rows
    /// that reference a cell (e.g. all `orders.customer_id` for a `users.id`).
    /// Results are in tree order (schema, then table, then column position).
    public func incomingReferences(toSchema schema: String, table: String,
                                   column: String) -> [ForeignKeyTarget] {
        let target = ForeignKeyTarget(schema: schema, table: table, column: column)
        var origins: [ForeignKeyTarget] = []
        for namespace in schemas {
            for referencing in namespace.tables {
                for col in referencing.columns where col.references == target {
                    origins.append(ForeignKeyTarget(schema: namespace.name,
                                                    table: referencing.name,
                                                    column: col.name))
                }
            }
        }
        return origins
    }
}
