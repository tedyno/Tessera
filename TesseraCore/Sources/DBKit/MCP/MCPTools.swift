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
                        + "connections. Returns the hits plus which connections were searched and "
                        + "which were skipped because their schema isn't loaded yet.",
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

        tool(name: "export_dump",
             description: "Dump a connection (optionally limited to schemas or tables) with "
                        + "pg_dump/mysqldump. The user approves it first, and Tessera chooses the "
                        + "destination inside their export folder — the path cannot be set here. "
                        + "Returns the file that was written.",
             properties: ["connection": stringSchema("Connection name."),
                          "schemas": arraySchema("Optional schemas to limit the dump to."),
                          "tables": arraySchema("Optional tables to limit the dump to."),
                          "structure": booleanSchema("Include CREATE statements (default true)."),
                          "data": booleanSchema("Include row data (default true)."),
                          "gzip": booleanSchema("Compress the dump with gzip (default false).")],
             required: ["connection"]),

        tool(name: "import_dump",
             description: "Restore a .sql, .sql.gz, or .dump file into a connection. Writes to the "
                        + "database, so the user approves it first; refused on connections marked "
                        + "read-only.",
             properties: ["connection": stringSchema("Connection name."),
                          "file": stringSchema("Absolute path of the dump file to restore.")],
             required: ["connection", "file"]),
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

    private static func booleanSchema(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func arraySchema(_ description: String) -> JSONValue {
        .object(["type": .string("array"),
                 "items": .object(["type": .string("string")]),
                 "description": .string(description)])
    }
}
