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

        tool(name: "export_result",
             description: "Run a read-only query and save its rows to a file as csv, xlsx "
                        + "(Excel), json, or sql (INSERT statements). The user approves it "
                        + "first, and Tessera chooses the destination inside their export "
                        + "folder — the path cannot be set here.",
             properties: ["connection": stringSchema("Connection name."),
                          "sql": stringSchema("A single read-only statement."),
                          "format": stringSchema("csv, xlsx, json or sql (default csv)."),
                          "limit": integerSchema("Maximum rows to export.")],
             required: ["connection", "sql"]),

        tool(name: "export_diagram",
             description: "Render the ER diagram of a schema — or of one table and its direct "
                        + "FK neighbors — to a PNG image. Runs without approval (it reveals "
                        + "nothing beyond what describe_table already returns); Tessera chooses "
                        + "the destination inside the user's export folder — the path cannot be "
                        + "set here. Returns the file that was written.",
             properties: ["connection": stringSchema("Connection name."),
                          "schema": stringSchema("Schema to diagram."),
                          "table": stringSchema("Optional: limit the diagram to this table "
                                              + "and its direct FK neighbors."),
                          "keys_only": booleanSchema("Show only PK/FK columns (default false)."),
                          "only_connected": booleanSchema("Hide tables without any FK edge "
                                                        + "(whole-schema scope only; defaults to "
                                                        + "on for schemas over 150 tables)."),
                          "edge_style": stringSchema("curved or orthogonal (default curved)."),
                          "background": stringSchema("plain, dots or grid (default plain).")],
             required: ["connection", "schema"]),

        tool(name: "import_dump",
             description: "Restore a .sql, .sql.gz, or .dump file into a connection. Writes to the "
                        + "database, so the user approves it first; refused on connections marked "
                        + "read-only.",
             properties: ["connection": stringSchema("Connection name."),
                          "file": stringSchema("Absolute path of the dump file to restore.")],
             required: ["connection", "file"]),

        // MARK: Connection management (no approval; sees every connection)

        tool(name: "list_organizer",
             description: "The full connection tree — workspaces, projects, folders and every "
                        + "connection, including ones not exposed to MCP. Use the ids from here "
                        + "with the other management tools.",
             properties: [:], required: []),

        tool(name: "create_connection",
             description: "Create a connection. MCP access is always off on a new connection — "
                        + "the user turns that on in Tessera. A password may be given here and "
                        + "nowhere else; it goes straight to the Keychain.",
             properties: ["name": stringSchema("Display name."),
                          "engine": stringSchema("postgres, mysql, mariadb or sqlite."),
                          "host": stringSchema("Database host (not used for sqlite)."),
                          "port": integerSchema("Port; defaults to the engine's standard port."),
                          "database": stringSchema("Database name; for sqlite, the file path."),
                          "user": stringSchema("Database user."),
                          "password": stringSchema("Optional password, stored in the Keychain."),
                          "tls": stringSchema("disable, prefer, require, verify-ca or verify-full."),
                          "parent_id": stringSchema("Workspace/project/folder id to file it under."),
                          "read_only": booleanSchema("Mark the connection read-only."),
                          "ssh_alias": stringSchema("Tunnel through this Host alias from "
                                                    + "~/.ssh/config; hostname, user, port and key "
                                                    + "are read from there at connect time."),
                          "ssh_host": stringSchema("SSH host, for a tunnel not in ~/.ssh/config."),
                          "ssh_port": integerSchema("SSH port (default 22)."),
                          "ssh_user": stringSchema("SSH user."),
                          "ssh_key_path": stringSchema("Path to the SSH private key.")],
             required: ["name", "engine", "database"]),

        tool(name: "update_connection",
             description: "Change an existing connection. The password cannot be changed here, "
                        + "and MCP access flags are left alone. Changing the host, port, database, "
                        + "or user points the connection somewhere else, so the stored password is "
                        + "discarded and the user is asked for it again on the next connect.",
             properties: ["connection_id": stringSchema("Connection id from list_organizer."),
                          "name": stringSchema("New display name."),
                          "host": stringSchema("New host."),
                          "port": integerSchema("New port."),
                          "database": stringSchema("New database."),
                          "user": stringSchema("New user."),
                          "tls": stringSchema("New TLS mode."),
                          "read_only": booleanSchema("Mark the connection read-only."),
                          "color": stringSchema("Dot colour, or empty to clear.")],
             required: ["connection_id"]),

        tool(name: "duplicate_connection",
             description: "Copy a connection, secrets and all, into the same place as the "
                        + "original. MCP access is always off on the copy — even when the "
                        + "original had it — so duplicating can never hand a client access "
                        + "the user didn't grant. The user turns it on in Tessera.",
             properties: ["connection_id": stringSchema("Connection id from list_organizer."),
                          "name": stringSchema("Optional name for the copy; defaults to the "
                                               + "original's name.")],
             required: ["connection_id"]),

        tool(name: "delete_connection",
             description: "Delete a connection. It goes to a small trash first, so it can be put "
                        + "back with restore_connection until the trash is purged.",
             properties: ["connection_id": stringSchema("Connection id from list_organizer.")],
             required: ["connection_id"]),

        tool(name: "restore_connection",
             description: "Put a deleted connection back, with its password intact.",
             properties: ["connection_id": stringSchema("Id of a connection in the trash.")],
             required: ["connection_id"]),

        tool(name: "move_connection",
             description: "File a connection under a different workspace, project, or folder.",
             properties: ["connection_id": stringSchema("Connection id from list_organizer."),
                          "parent_id": stringSchema("Target workspace/project/folder id."),
                          "index": integerSchema("Optional position among the parent's children.")],
             required: ["connection_id", "parent_id"]),

        tool(name: "create_container",
             description: "Create a workspace, project, or folder to organize connections into.",
             properties: ["name": stringSchema("Display name."),
                          "kind": stringSchema("workspace, project, or folder."),
                          "parent_id": stringSchema("Parent id; omit for a workspace.")],
             required: ["name", "kind"]),
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
