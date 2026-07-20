import Foundation

public struct MCPConnectionInfo: Codable, Equatable, Sendable {
    public let name: String
    public let engine: String
    public let database: String
    /// Whether MCP may run writing statements here (still approved per call).
    /// Granted per connection and capped by the connection's read-only flag.
    public let canWrite: Bool
    public let isConnected: Bool

    public init(name: String, engine: String, database: String,
                canWrite: Bool, isConnected: Bool) {
        self.name = name
        self.engine = engine
        self.database = database
        self.canWrite = canWrite
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

/// Search results plus which connections actually contributed — a connection whose
/// schema hasn't been introspected yet is skipped, so results would otherwise look
/// complete when they aren't.
public struct MCPSearchResult: Codable, Equatable, Sendable {
    public let hits: [MCPSearchHit]
    public let searched: [String]
    /// Exposed connections skipped because they aren't connected/introspected yet.
    public let skipped: [String]

    public init(hits: [MCPSearchHit], searched: [String], skipped: [String]) {
        self.hits = hits
        self.searched = searched
        self.skipped = skipped
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
/// One cell in an MCP result. Values from numeric columns are emitted as real JSON
/// numbers; anything that wouldn't survive that exactly stays text, so a big `int8`
/// or a high-precision `numeric` is never silently rounded.
public enum MCPValue: Codable, Equatable, Sendable {
    case null
    case int(Int)
    case double(Double)
    case text(String)

    /// Largest integer a JSON consumer using IEEE-754 doubles can hold exactly.
    private static let exactIntegerLimit = 1 << 53

    /// Classifies a cell, converting to a number only when it is lossless.
    public static func make(_ text: String?, isNumericColumn: Bool) -> MCPValue {
        guard let text else { return .null }
        guard isNumericColumn else { return .text(text) }
        if let value = Int(text), abs(value) <= exactIntegerLimit { return .int(value) }
        // Accept a decimal only when its shortest round-trip is the original text.
        if let value = Double(text), value.isFinite, String(value) == text { return .double(value) }
        return .text(text)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else { self = .text(try container.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }
}

public struct MCPQueryResult: Codable, Equatable, Sendable {
    public let columns: [String]
    public let rows: [[MCPValue]]
    public let rowCount: Int
    /// Rows changed by a write (INSERT/UPDATE/DELETE); nil for row-returning queries.
    public let rowsAffected: Int?
    public let truncated: Bool

    public init(columns: [String], rows: [[MCPValue]], truncated: Bool, rowsAffected: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rows.count
        self.rowsAffected = rowsAffected
        self.truncated = truncated
    }

    /// Convenience for simple callers: every cell treated as text. Distinct label so
    /// an empty literal never makes the two initialisers ambiguous.
    public init(columns: [String], textRows: [[String?]], truncated: Bool, rowsAffected: Int? = nil) {
        self.init(columns: columns,
                  rows: textRows.map { $0.map { MCPValue.make($0, isNumericColumn: false) } },
                  truncated: truncated, rowsAffected: rowsAffected)
    }

    /// Builds from a driver result, typing numeric columns as JSON numbers.
    public init(_ result: QueryResult) {
        let numericColumn = result.columns.map { SQLTypes.isNumeric($0.typeName) }
        self.init(columns: result.columns.map(\.name),
                  rows: result.rows.map { row in
                      row.enumerated().map { index, cell in
                          MCPValue.make(cell.text, isNumericColumn: index < numericColumn.count && numericColumn[index])
                      }
                  },
                  truncated: result.isTruncated,
                  rowsAffected: result.rowsAffected)
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
    func search(term: String) async -> MCPSearchResult

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

    /// Reports which MCP client connected (from `initialize`), so approval prompts can
    /// name it. Any client can speak MCP, so this is never assumed.
    func clientIdentified(name: String, version: String?) async

    // MARK: Connection management
    //
    // These see every connection, not just the MCP-enabled ones, so the whole tree
    // can be organized. They run without approval, which is safe only because a
    // client can neither grant itself access nor carry a password to a new server.

    func organizer() async -> [MCPOrganizerNode]
    func createConnection(_ spec: MCPConnectionSpec) async throws -> MCPConnectionSummary
    func updateConnection(id: String, changes: MCPConnectionChanges) async throws -> MCPConnectionSummary
    func deleteConnection(id: String) async throws -> MCPConnectionSummary
    func restoreConnection(id: String) async throws -> MCPConnectionSummary
    func moveConnection(id: String, parentID: String, index: Int?) async throws -> MCPConnectionSummary
    func createContainer(name: String, kind: String, parentID: String?) async throws -> MCPOrganizerNode
}

public extension MCPDataSource {
    func clientIdentified(name: String, version: String?) async {}

    // Default to "this build doesn't manage connections" so a data source can
    // implement only the query half of the protocol.
    private var unmanaged: MCPToolError { MCPToolError("Connection management is not available.") }

    func organizer() async -> [MCPOrganizerNode] { [] }
    func createConnection(_ spec: MCPConnectionSpec) async throws -> MCPConnectionSummary { throw unmanaged }
    func updateConnection(id: String, changes: MCPConnectionChanges) async throws -> MCPConnectionSummary { throw unmanaged }
    func deleteConnection(id: String) async throws -> MCPConnectionSummary { throw unmanaged }
    func restoreConnection(id: String) async throws -> MCPConnectionSummary { throw unmanaged }
    func moveConnection(id: String, parentID: String, index: Int?) async throws -> MCPConnectionSummary { throw unmanaged }
    func createContainer(name: String, kind: String, parentID: String?) async throws -> MCPOrganizerNode { throw unmanaged }
}
