import Foundation

/// A table column in the schema browser.
public struct SchemaColumn: Sendable, Hashable, Identifiable {
    public var name: String
    public var dataType: String
    public var isPrimaryKey: Bool
    public var isForeignKey: Bool
    public var isNullable: Bool

    public var id: String { name }

    public init(name: String, dataType: String, isPrimaryKey: Bool = false,
                isForeignKey: Bool = false, isNullable: Bool = true) {
        self.name = name
        self.dataType = dataType
        self.isPrimaryKey = isPrimaryKey
        self.isForeignKey = isForeignKey
        self.isNullable = isNullable
    }
}

/// An index on a table.
public struct SchemaIndex: Sendable, Hashable, Identifiable {
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
public struct SchemaTable: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
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
public struct SchemaNamespace: Sendable, Hashable, Identifiable {
    public var name: String
    public var tables: [SchemaTable]

    public var id: String { name }

    public init(name: String, tables: [SchemaTable] = []) {
        self.name = name
        self.tables = tables
    }
}

/// Schema tree of a single database (Database → Schema → Table → Column).
/// A runtime structure produced after connecting — **never persisted**.
public struct DatabaseTree: Sendable, Hashable {
    public var databaseName: String
    public var schemas: [SchemaNamespace]

    public init(databaseName: String, schemas: [SchemaNamespace] = []) {
        self.databaseName = databaseName
        self.schemas = schemas
    }
}
