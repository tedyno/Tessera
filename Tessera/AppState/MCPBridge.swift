import Foundation
import DBKit

/// Serves the MCP core from the app's live state. Only connections that granted MCP
/// read access are ever visible here — the core never learns the others exist.
/// Writes, imports, and exports go through the approval prompt.
@MainActor
final class MCPBridge: MCPDataSource {
    unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    /// Records which client spoke `initialize`, so prompts name it accurately —
    /// Tessera's MCP server is open to any client, not just one vendor's.
    func clientIdentified(name: String, version: String?) async {
        app.mcpClientName = version.map { "\(name) \($0)" } ?? name
        app.mcpAudit.client = app.mcpClientLabel
    }

    // MARK: Exposed connections

    /// Profiles that opted in, keyed by a name unique among them (two connections
    /// may share a name in different folders, so those get their folder appended).
    private var exposed: [String: ConnectionProfile] {
        let profiles = app.connections.profiles.filter(\.allowsMCPRead)
        var counts: [String: Int] = [:]
        for profile in profiles { counts[profile.name, default: 0] += 1 }
        var result: [String: ConnectionProfile] = [:]
        for profile in profiles {
            if counts[profile.name] == 1 {
                result[profile.name] = profile
            } else {
                let folder = app.connections.path(forProfile: profile.id).last ?? profile.database
                result["\(profile.name) (\(folder))"] = profile
            }
        }
        return result
    }

    private func info(name: String, profile: ConnectionProfile) -> MCPConnectionInfo {
        MCPConnectionInfo(name: name,
                          engine: profile.kind.displayName,
                          database: profile.database,
                          canWrite: profile.allowsMCPWrite,
                          isConnected: app.console.session(for: profile.id)?.isReady ?? false)
    }

    func listConnections() async -> [MCPConnectionInfo] {
        exposed.map { info(name: $0.key, profile: $0.value) }.sorted { $0.name < $1.name }
    }

    func connection(named name: String) async -> MCPConnectionInfo? {
        guard let profile = exposed[name] else { return nil }
        return info(name: name, profile: profile)
    }

    private func profile(_ name: String) throws -> ConnectionProfile {
        guard let profile = exposed[name] else {
            throw MCPToolError("Unknown connection “\(name)”.")
        }
        return profile
    }

    /// Connects on demand — MCP shouldn't fail just because a tab isn't open yet.
    private func readySession(_ name: String) async throws -> ConnectionSession {
        let profile = try profile(name)
        guard let session = await app.ensureSessionReady(profileID: profile.id) else {
            throw MCPToolError("Could not connect to “\(name)”: "
                               + (app.console.session(for: profile.id)?.errorMessage ?? "unavailable"))
        }
        // A session can be ready before its schema has ever been read (or after a
        // failed introspection); MCP introspection tools depend on it.
        if session.schema == nil { await session.refreshSchema() }
        return session
    }

    // MARK: Introspection

    func serverInfo(connection: String) async throws -> [String: String] {
        let session = try await readySession(connection)
        return ["engine": session.engine.displayName,
                "version": session.serverVersion ?? "unknown",
                "database": session.database ?? ""]
    }

    func listSchemas(connection: String) async throws -> [String] {
        let session = try await readySession(connection)
        return (session.schema?.schemas ?? []).map(\.name)
    }

    func listTables(connection: String, schema: String?) async throws -> [MCPTableInfo] {
        let session = try await readySession(connection)
        return (session.schema?.schemas ?? [])
            .filter { schema == nil || $0.name == schema }
            .flatMap { namespace in
                namespace.tables.map {
                    MCPTableInfo(schema: namespace.name, name: $0.name,
                                 kind: $0.kind == .view ? "view" : "table")
                }
            }
    }

    func describeTable(connection: String, schema: String?, table: String) async throws -> MCPTableDetail {
        let session = try await readySession(connection)
        if let detail = Self.detail(in: session.schema, schema: schema, table: table) { return detail }
        // The cached schema may predate a table created since we introspected —
        // re-read it once before declaring the table missing.
        await session.refreshSchema()
        if let detail = Self.detail(in: session.schema, schema: schema, table: table) { return detail }
        throw MCPToolError("Table “\(table)” not found on “\(connection)”.")
    }

    private static func detail(in tree: DatabaseTree?, schema: String?, table: String) -> MCPTableDetail? {
        for namespace in tree?.schemas ?? [] {
            guard schema == nil || namespace.name == schema else { continue }
            guard let match = namespace.tables.first(where: {
                $0.name.caseInsensitiveCompare(table) == .orderedSame
            }) else { continue }
            return MCPTableDetail(
                schema: namespace.name,
                table: match.name,
                columns: match.columns.map {
                    MCPColumnInfo(name: $0.name, type: $0.dataType, nullable: $0.isNullable,
                                  primaryKey: $0.isPrimaryKey, foreignKey: $0.isForeignKey,
                                  autoIncrement: $0.isAutoIncrement)
                },
                indexes: match.indexes.map {
                    MCPIndexInfo(name: $0.name, columns: $0.columns, unique: $0.isUnique)
                })
        }
        return nil
    }

    func search(term: String) async -> MCPSearchResult {
        let needle = term.lowercased()
        guard !needle.isEmpty else { return MCPSearchResult(hits: [], searched: [], skipped: []) }
        var hits: [MCPSearchHit] = []
        var searched: [String] = []
        var skipped: [String] = []
        for (name, profile) in exposed {
            // Never connect just to search — that would prompt for Keychain access
            // behind the user's back. Report the gap instead of hiding it.
            guard let tree = app.console.session(for: profile.id)?.schema else {
                skipped.append(name)
                continue
            }
            searched.append(name)
            for namespace in tree.schemas {
                if namespace.name.lowercased().contains(needle) {
                    hits.append(MCPSearchHit(connection: name, schema: namespace.name,
                                             table: nil, column: nil))
                }
                for table in namespace.tables {
                    if table.name.lowercased().contains(needle) {
                        hits.append(MCPSearchHit(connection: name, schema: namespace.name,
                                                 table: table.name, column: nil))
                    }
                    for column in table.columns where column.name.lowercased().contains(needle) {
                        hits.append(MCPSearchHit(connection: name, schema: namespace.name,
                                                 table: table.name, column: column.name))
                    }
                }
            }
        }
        return MCPSearchResult(hits: Array(hits.prefix(100)),
                               searched: searched.sorted(), skipped: skipped.sorted())
    }

    // MARK: Queries

    func runReadQuery(connection: String, sql: String, limit: Int?) async throws -> MCPQueryResult {
        let session = try await readySession(connection)
        guard let driver = session.driver else { throw MCPToolError("Not connected.") }
        let cap = limit ?? (ExportSettings.maxRows > 0 ? ExportSettings.maxRows : nil)
        do {
            let result = try await driver.execute(sql, maxRows: cap)
            app.mcpAudit.record(tool: "run_query", connection: connection, detail: sql,
                                outcome: "\(result.rows.count) rows")
            return MCPQueryResult(result)
        } catch {
            let message = ConnectionSession.message(for: error)
            app.mcpAudit.record(tool: "run_query", connection: connection, detail: sql,
                                outcome: "failed: \(message)")
            throw MCPToolError(message)
        }
    }

    func runWriteQuery(connection: String, sql: String) async throws -> MCPQueryResult {
        let profile = try profile(connection)
        // Belt and braces: the core checks this too.
        guard profile.allowsMCPWrite else {
            throw MCPToolError("“\(connection)” is not permitted to write over MCP.")
        }
        // The connection may be configured to run writes unattended; that is the only
        // way the prompt is skipped, and it stays visible in the audit log.
        if profile.allowsMCPWriteWithoutApproval {
            app.mcpAudit.record(tool: "run_query (write)", connection: connection,
                                detail: sql, outcome: "auto-approved (approval not required)")
        } else {
            let outcome = await app.mcpApprovals.request(
                title: "\(app.mcpClientLabel) wants to modify “\(connection)”",
                connection: connection, detail: sql)
            guard outcome.isApproved else {
                app.mcpAudit.record(tool: "run_query (write)", connection: connection,
                                    detail: sql, outcome: outcome.auditLabel)
                throw MCPToolError(outcome.message("write"))
            }
        }
        let session = try await readySession(connection)
        guard let driver = session.driver else { throw MCPToolError("Not connected.") }
        do {
            let result = try await driver.execute(sql, maxRows: nil)
            app.mcpAudit.record(tool: "run_query (write)", connection: connection,
                                detail: sql, outcome: "applied")
            await session.refreshSchema()
            return MCPQueryResult(result)
        } catch {
            let message = ConnectionSession.message(for: error)
            app.mcpAudit.record(tool: "run_query (write)", connection: connection,
                                detail: sql, outcome: "failed: \(message)")
            throw MCPToolError(message)
        }
    }

    // MARK: Dumps

    func exportDump(connection: String, schemas: [String], tables: [String],
                    structure: Bool, data: Bool, gzip: Bool) async throws -> MCPExportResult {
        let profile = try profile(connection)
        let scope = tables.isEmpty ? (schemas.isEmpty ? "the whole database" : schemas.joined(separator: ", "))
                                   : tables.joined(separator: ", ")
        let outcome = await app.mcpApprovals.request(
            title: "\(app.mcpClientLabel) wants to export “\(connection)”", connection: connection,
            detail: "Dump \(scope)\(gzip ? " (gzipped)" : "") into your export folder.")
        guard outcome.isApproved else {
            app.mcpAudit.record(tool: "export_dump", connection: connection,
                                detail: scope, outcome: outcome.auditLabel)
            throw MCPToolError(outcome.message("export"))
        }
        do {
            let result = try await app.runMCPExport(profile: profile, schemas: schemas, tables: tables,
                                                    structure: structure, data: data, gzip: gzip)
            app.mcpAudit.record(tool: "export_dump", connection: connection,
                                detail: scope, outcome: "wrote \(result.path)")
            return result
        } catch {
            // The user approved it and pg_dump really ran — a failure belongs in the log.
            app.mcpAudit.record(tool: "export_dump", connection: connection,
                                detail: scope, outcome: "failed: \(Self.message(for: error))")
            throw error
        }
    }

    func importDump(connection: String, filePath: String) async throws -> MCPImportResult {
        let profile = try profile(connection)
        guard profile.allowsMCPWrite else {
            throw MCPToolError("“\(connection)” is not permitted to write over MCP.")
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw MCPToolError("No file at \(filePath).")
        }
        let outcome = await app.mcpApprovals.request(
            title: "\(app.mcpClientLabel) wants to import into “\(connection)”", connection: connection,
            detail: "Restore \(filePath). This writes to the database and can overwrite data.")
        guard outcome.isApproved else {
            app.mcpAudit.record(tool: "import_dump", connection: connection,
                                detail: filePath, outcome: outcome.auditLabel)
            throw MCPToolError(outcome.message("import"))
        }
        do {
            let result = try await app.runMCPImport(profile: profile, filePath: filePath)
            app.mcpAudit.record(tool: "import_dump", connection: connection,
                                detail: filePath, outcome: result.message)
            return result
        } catch {
            // A half-applied restore is exactly what the log exists for.
            app.mcpAudit.record(tool: "import_dump", connection: connection,
                                detail: filePath, outcome: "failed: \(Self.message(for: error))")
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        (error as? MCPToolError)?.message ?? ConnectionSession.message(for: error)
    }
}
