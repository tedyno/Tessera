import Foundation

/// The MCP server's protocol layer: turns JSON-RPC requests into calls on an
/// `MCPDataSource`. Transport-agnostic and pure, so the policy below is testable.
///
/// Access rules enforced here (the app enforces them again — defence in depth):
/// * only connections the app exposes are visible at all,
/// * a single statement per call,
/// * reads run directly; writes need approval and are refused on read-only
///   connections.
public struct MCPService: Sendable {
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "tessera"

    private let source: any MCPDataSource
    private let serverVersion: String

    public init(source: any MCPDataSource, serverVersion: String = "1.0.0") {
        self.source = source
        self.serverVersion = serverVersion
    }

    /// Handles one JSON-RPC message. Returns nil for notifications (no reply).
    public func handle(_ data: Data) async -> Data? {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            return encode(JSONRPCResponse(id: nil, error: .invalidRequest("Malformed JSON-RPC request.")))
        }
        if request.isNotification {
            return nil   // e.g. "notifications/initialized"
        }
        let response: JSONRPCResponse
        switch request.method {
        case "initialize":
            // Remember who connected (Claude Code, Codex, an editor…) so approval
            // prompts can name the actual client instead of guessing.
            if let info = request.params?.objectValue?["clientInfo"]?.objectValue,
               let name = info["name"]?.stringValue, !name.isEmpty {
                await source.clientIdentified(name: name, version: info["version"]?.stringValue)
            }
            response = JSONRPCResponse(id: request.id, result: initializeResult)
        case "ping":
            response = JSONRPCResponse(id: request.id, result: .object([:]))
        case "tools/list":
            response = JSONRPCResponse(id: request.id, result: .object(["tools": MCPTools.catalog]))
        case "tools/call":
            response = await callTool(request)
        default:
            response = JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
        return encode(response)
    }

    private var initializeResult: JSONValue {
        .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(serverVersion),
            ]),
        ])
    }

    // MARK: Tool dispatch

    private func callTool(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            return JSONRPCResponse(id: request.id, error: .invalidParams("Missing tool name."))
        }
        let arguments = params["arguments"]?.objectValue ?? [:]
        do {
            let payload = try await run(tool: name, arguments: arguments)
            return JSONRPCResponse(id: request.id, result: toolContent(payload, isError: false))
        } catch let error as MCPToolError {
            // Tool-level failures come back as content, per MCP, so the model can react.
            return JSONRPCResponse(id: request.id, result: toolContent(.string(error.message), isError: true))
        } catch let error as MCPSQLPolicy.Rejection {
            return JSONRPCResponse(id: request.id, result: toolContent(.string(error.reason), isError: true))
        } catch {
            return JSONRPCResponse(id: request.id, result: toolContent(.string(String(describing: error)),
                                                                       isError: true))
        }
    }

    private func run(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch tool {
        case "list_connections":
            return try encodeJSON(await source.listConnections())

        case "server_info":
            let connection = try string(arguments, "connection")
            try await requireConnection(connection)
            return try encodeJSON(await source.serverInfo(connection: connection))

        case "list_schemas":
            let connection = try string(arguments, "connection")
            try await requireConnection(connection)
            return try encodeJSON(await source.listSchemas(connection: connection))

        case "list_tables":
            let connection = try string(arguments, "connection")
            try await requireConnection(connection)
            return try encodeJSON(await source.listTables(connection: connection,
                                                          schema: arguments["schema"]?.stringValue))

        case "describe_table":
            let connection = try string(arguments, "connection")
            try await requireConnection(connection)
            let table = try string(arguments, "table")
            return try encodeJSON(await source.describeTable(connection: connection,
                                                             schema: arguments["schema"]?.stringValue,
                                                             table: table))

        case "search":
            return try encodeJSON(await source.search(term: try string(arguments, "term")))

        case "sample_table":
            let connection = try string(arguments, "connection")
            let info = try await requireConnection(connection)
            let table = try string(arguments, "table")
            let schema = arguments["schema"]?.stringValue
            let limit = arguments["limit"]?.intValue ?? 20
            let engine: DatabaseKind = info.engine.lowercased().contains("mysql") ? .mysql : .postgres
            let target = SchemaDDL.qualified(schema: schema, table: table, for: engine)
            let sql = "SELECT * FROM \(target) LIMIT \(max(1, limit))"
            return try encodeJSON(await source.runReadQuery(connection: connection, sql: sql, limit: limit))

        case "explain_query":
            let connection = try string(arguments, "connection")
            try await requireConnection(connection)
            let sql = try string(arguments, "sql")
            // Guard the inner statement, then explain it — EXPLAIN alone never writes.
            let (statement, access) = try MCPSQLPolicy.classify(sql)
            guard access == .readOnly else {
                throw MCPToolError("Only read-only statements can be explained over MCP.")
            }
            // SHOW/DESCRIBE are read-only but cannot be EXPLAINed — building
            // "EXPLAIN SHOW …" would just produce a syntax error at the server.
            guard statement.range(of: "^\\s*(SELECT|WITH|TABLE|VALUES)\\b",
                                  options: [.regularExpression, .caseInsensitive]) != nil else {
                throw MCPToolError("Only SELECT-style statements can be explained.")
            }
            return try encodeJSON(await source.runReadQuery(connection: connection,
                                                            sql: "EXPLAIN \(statement)", limit: nil))

        case "run_query":
            return try await runQuery(arguments)

        case "export_dump":
            let connection = try string(arguments, "connection")
            try await requireConnection(connection)
            // Reading data out is safe for the database, but it writes a file, so the
            // app still asks. The destination is chosen by the app, not by MCP.
            return try encodeJSON(await source.exportDump(
                connection: connection,
                schemas: stringList(arguments, "schemas"),
                tables: stringList(arguments, "tables"),
                structure: arguments["structure"].flatMap(boolValue) ?? true,
                data: arguments["data"].flatMap(boolValue) ?? true,
                gzip: arguments["gzip"].flatMap(boolValue) ?? false))

        case "import_dump":
            let connection = try string(arguments, "connection")
            let info = try await requireConnection(connection)
            guard info.canWrite else {
                throw MCPToolError("“\(connection)” is not permitted to write over MCP, "
                                   + "so importing is refused.")
            }
            return try encodeJSON(await source.importDump(connection: connection,
                                                          filePath: try string(arguments, "file")))

        // MARK: Connection management
        //
        // No approval and no `requireConnection`: these manage the organizer itself
        // and deliberately see connections that aren't exposed for querying.

        case "list_organizer":
            return try encodeJSON(await source.organizer())

        case "create_connection":
            let spec = MCPConnectionSpec(
                name: try string(arguments, "name"),
                engine: try string(arguments, "engine"),
                host: try string(arguments, "host"),
                port: arguments["port"]?.intValue,
                database: try string(arguments, "database"),
                user: try string(arguments, "user"),
                password: arguments["password"]?.stringValue,
                tls: arguments["tls"]?.stringValue,
                parentID: arguments["parent_id"]?.stringValue,
                readOnly: arguments["read_only"]?.boolValue)
            return try encodeJSON(await source.createConnection(spec))

        case "update_connection":
            let changes = MCPConnectionChanges(
                name: arguments["name"]?.stringValue,
                host: arguments["host"]?.stringValue,
                port: arguments["port"]?.intValue,
                database: arguments["database"]?.stringValue,
                user: arguments["user"]?.stringValue,
                tls: arguments["tls"]?.stringValue,
                readOnly: arguments["read_only"]?.boolValue,
                color: arguments["color"]?.stringValue)
            return try encodeJSON(await source.updateConnection(
                id: try string(arguments, "connection_id"), changes: changes))

        case "delete_connection":
            return try encodeJSON(await source.deleteConnection(
                id: try string(arguments, "connection_id")))

        case "restore_connection":
            return try encodeJSON(await source.restoreConnection(
                id: try string(arguments, "connection_id")))

        case "move_connection":
            return try encodeJSON(await source.moveConnection(
                id: try string(arguments, "connection_id"),
                parentID: try string(arguments, "parent_id"),
                index: arguments["index"]?.intValue))

        case "create_container":
            return try encodeJSON(await source.createContainer(
                name: try string(arguments, "name"),
                kind: try string(arguments, "kind"),
                parentID: arguments["parent_id"]?.stringValue))

        default:
            throw MCPToolError("Unknown tool: \(tool)")
        }
    }

    /// The security-critical path: classify, then read directly or route writes
    /// through approval — never on a read-only connection.
    private func runQuery(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let connection = try string(arguments, "connection")
        let info = try await requireConnection(connection)
        let sql = try string(arguments, "sql")
        let (statement, access) = try MCPSQLPolicy.classify(sql)

        switch access {
        case .readOnly:
            let limit = arguments["limit"]?.intValue
            return try encodeJSON(await source.runReadQuery(connection: connection,
                                                            sql: statement, limit: limit))
        case .write:
            guard info.canWrite else {
                throw MCPToolError("“\(connection)” is not permitted to write over MCP "
                                   + "(enable it for this connection in Tessera; a read-only "
                                   + "connection can never be granted write access).")
            }
            return try encodeJSON(await source.runWriteQuery(connection: connection, sql: statement))
        }
    }

    // MARK: Helpers

    @discardableResult
    private func requireConnection(_ name: String) async throws -> MCPConnectionInfo {
        guard let info = await source.connection(named: name) else {
            throw MCPToolError("Unknown connection “\(name)”. It may not exist, or MCP access "
                               + "is not enabled for it in Tessera.")
        }
        return info
    }

    private func stringList(_ arguments: [String: JSONValue], _ key: String) -> [String] {
        guard case .array(let values)? = arguments[key] else { return [] }
        return values.compactMap(\.stringValue)
    }

    private func boolValue(_ value: JSONValue) -> Bool? {
        if case .bool(let flag) = value { return flag }
        return nil
    }

    private func string(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw MCPToolError("Missing required argument “\(key)”.")
        }
        return value
    }

    /// MCP tool results are a list of content blocks; JSON goes in a text block.
    private func toolContent(_ payload: JSONValue, isError: Bool) -> JSONValue {
        let text: String
        if case .string(let message) = payload {
            text = message
        } else {
            text = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) as? String
                ?? "{}"
        }
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func encode(_ response: JSONRPCResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
    }
}
