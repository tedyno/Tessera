import Foundation

public struct MCPConnectionInfo: Codable, Equatable, Sendable {
    public let name: String
    public let engine: String
    public let database: String
    public let isReadOnly: Bool
    public let isConnected: Bool

    public init(name: String, engine: String, database: String,
                isReadOnly: Bool, isConnected: Bool) {
        self.name = name
        self.engine = engine
        self.database = database
        self.isReadOnly = isReadOnly
        self.isConnected = isConnected
    }
}

public struct MCPTableInfo: Codable, Equatable, Sendable {
    public let schema: String
    public let name: String
    public let kind: String          // "table" or "view"

    public init(schema: String, name: String, kind: String) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }
}

public struct MCPColumnInfo: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let primaryKey: Bool
    public let foreignKey: Bool
    public let autoIncrement: Bool

    public init(name: String, type: String, nullable: Bool,
                primaryKey: Bool, foreignKey: Bool, autoIncrement: Bool) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.primaryKey = primaryKey
        self.foreignKey = foreignKey
        self.autoIncrement = autoIncrement
    }
}

public struct MCPIndexInfo: Codable, Equatable, Sendable {
    public let name: String
    public let columns: [String]
    public let unique: Bool

    public init(name: String, columns: [String], unique: Bool) {
        self.name = name
        self.columns = columns
        self.unique = unique
    }
}

public struct MCPTableDetail: Codable, Equatable, Sendable {
    public let schema: String
    public let table: String
    public let columns: [MCPColumnInfo]
    public let indexes: [MCPIndexInfo]

    public init(schema: String, table: String, columns: [MCPColumnInfo], indexes: [MCPIndexInfo]) {
        self.schema = schema
        self.table = table
        self.columns = columns
        self.indexes = indexes
    }
}

public struct MCPSearchHit: Codable, Equatable, Sendable {
    public let connection: String
    public let schema: String?
    public let table: String?
    public let column: String?

    public init(connection: String, schema: String?, table: String?, column: String?) {
        self.connection = connection
        self.schema = schema
        self.table = table
        self.column = column
    }
}

/// Rows are plain strings (nil = SQL NULL) so any column type serializes safely.
public struct MCPQueryResult: Codable, Equatable, Sendable {
    public let columns: [String]
    public let rows: [[String?]]
    public let rowCount: Int
    public let truncated: Bool

    public init(columns: [String], rows: [[String?]], truncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rows.count
        self.truncated = truncated
    }

    /// Builds from a driver result.
    public init(_ result: QueryResult) {
        self.init(columns: result.columns.map(\.name),
                  rows: result.rows.map { row in row.map(\.text) },
                  truncated: result.isTruncated)
    }
}

public struct MCPExportResult: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int

    public init(path: String, bytes: Int) {
        self.path = path
        self.bytes = bytes
    }
}

public struct MCPImportResult: Codable, Equatable, Sendable {
    public let file: String
    public let message: String

    public init(file: String, message: String) {
        self.file = file
        self.message = message
    }
}

public struct MCPToolError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// What the MCP server needs from the app. Only connections the user opted in to
/// may ever be returned here — the app filters, the core never sees the rest.
public protocol MCPDataSource: Sendable {
    func listConnections() async -> [MCPConnectionInfo]
    func connection(named name: String) async -> MCPConnectionInfo?
    func serverInfo(connection: String) async throws -> [String: String]
    func listSchemas(connection: String) async throws -> [String]
    func listTables(connection: String, schema: String?) async throws -> [MCPTableInfo]
    func describeTable(connection: String, schema: String?, table: String) async throws -> MCPTableDetail
    func search(term: String) async -> [MCPSearchHit]

    /// Runs a statement already classified as read-only.
    func runReadQuery(connection: String, sql: String, limit: Int?) async throws -> MCPQueryResult
    /// Runs a writing statement — the app must get the user's approval first and
    /// throw if they decline.
    func runWriteQuery(connection: String, sql: String) async throws -> MCPQueryResult

    /// Dumps the connection (or part of it) to a file. The app picks the destination
    /// inside the user's export folder — MCP never chooses a path on disk — and must
    /// get approval first.
    func exportDump(connection: String, schemas: [String], tables: [String],
                    structure: Bool, data: Bool, gzip: Bool) async throws -> MCPExportResult
    /// Restores a dump file. The app must show the file and get approval first.
    func importDump(connection: String, filePath: String) async throws -> MCPImportResult
}
