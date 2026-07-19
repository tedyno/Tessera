import Foundation

/// The tool catalog advertised by `tools/list`, with JSON Schema for each input.
enum MCPTools {
    static let catalog: JSONValue = .array([
        tool(name: "list_connections",
             description: "List the databases Tessera exposes over MCP (name, engine, database, "
                        + "whether it is read-only and currently connected).",
             properties: [:], required: []),

        tool(name: "server_info",
             description: "Engine and server version of a connection — useful to write "
                        + "version-appropriate SQL.",
             properties: ["connection": stringSchema("Connection name from list_connections.")],
             required: ["connection"]),

        tool(name: "list_schemas",
             description: "Schemas available on a connection (for MySQL this is the database).",
             properties: ["connection": stringSchema("Connection name.")],
             required: ["connection"]),

        tool(name: "list_tables",
             description: "Tables and views, optionally limited to one schema.",
             properties: ["connection": stringSchema("Connection name."),
                          "schema": stringSchema("Optional schema to limit to.")],
             required: ["connection"]),

        tool(name: "describe_table",
             description: "Columns (type, nullability, primary/foreign key, auto-increment) and "
                        + "indexes of a table. Read this before writing SQL against it.",
             properties: ["connection": stringSchema("Connection name."),
                          "schema": stringSchema("Optional schema."),
                          "table": stringSchema("Table name.")],
             required: ["connection", "table"]),

        tool(name: "search",
             description: "Find schemas, tables, or columns matching a term across all exposed "
                        + "connections.",
             properties: ["term": stringSchema("Text to look for.")],
             required: ["term"]),

        tool(name: "sample_table",
             description: "Return a few rows from a table without writing SQL. Always read-only.",
             properties: ["connection": stringSchema("Connection name."),
                          "schema": stringSchema("Optional schema."),
                          "table": stringSchema("Table name."),
                          "limit": integerSchema("Rows to return (default 20).")],
             required: ["connection", "table"]),

        tool(name: "explain_query",
             description: "Run EXPLAIN for a read-only query to inspect its plan.",
             properties: ["connection": stringSchema("Connection name."),
                          "sql": stringSchema("A single read-only statement.")],
             required: ["connection", "sql"]),

        tool(name: "run_query",
             description: "Run one SQL statement. Read-only statements (SELECT, WITH, EXPLAIN, "
                        + "SHOW…) run immediately. Writing statements require the user to approve "
                        + "them in Tessera, and are refused on connections marked read-only. "
                        + "Only one statement per call.",
             properties: ["connection": stringSchema("Connection name."),
                          "sql": stringSchema("A single SQL statement."),
                          "limit": integerSchema("Maximum rows to return for reads.")],
             required: ["connection", "sql"]),
    ])

    // MARK: Schema builders

    private static func tool(name: String, description: String,
                             properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
        ])
    }

    private static func stringSchema(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerSchema(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
