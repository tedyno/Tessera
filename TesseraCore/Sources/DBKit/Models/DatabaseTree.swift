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

    public var id: String { name }

    public init(name: String, kind: Kind = .table, columns: [SchemaColumn] = [],
                indexes: [SchemaIndex] = []) {
        self.name = name
        self.kind = kind
        self.columns = columns
        self.indexes = indexes
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
}
