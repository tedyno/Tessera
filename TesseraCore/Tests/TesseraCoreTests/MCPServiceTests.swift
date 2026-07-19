import XCTest
@testable import DBKit

/// Records what the service asked for, so tests can assert which path ran.
private actor FakeSource: MCPDataSource {
    var connections: [MCPConnectionInfo]
    private(set) var readQueries: [String] = []
    private(set) var writeQueries: [String] = []
    var approveWrites = true

    init(connections: [MCPConnectionInfo]) { self.connections = connections }

    func listConnections() async -> [MCPConnectionInfo] { connections }
    func connection(named name: String) async -> MCPConnectionInfo? {
        connections.first { $0.name == name }
    }
    func serverInfo(connection: String) async throws -> [String: String] { ["version": "16.2"] }
    func listSchemas(connection: String) async throws -> [String] { ["public"] }
    func listTables(connection: String, schema: String?) async throws -> [MCPTableInfo] {
        [MCPTableInfo(schema: "public", name: "customers", kind: "table")]
    }
    func describeTable(connection: String, schema: String?, table: String) async throws -> MCPTableDetail {
        MCPTableDetail(schema: "public", table: table, columns: [], indexes: [])
    }
    func search(term: String) async -> MCPSearchResult {
        MCPSearchResult(hits: [], searched: ["shop"], skipped: [])
    }

    func runReadQuery(connection: String, sql: String, limit: Int?) async throws -> MCPQueryResult {
        readQueries.append(sql)
        return MCPQueryResult(columns: ["id"], textRows: [["1"]], truncated: false)
    }
    func runWriteQuery(connection: String, sql: String) async throws -> MCPQueryResult {
        writeQueries.append(sql)
        guard approveWrites else { throw MCPToolError("The user declined the write.") }
        return MCPQueryResult(columns: [], textRows: [], truncated: false, rowsAffected: 1)
    }

    private(set) var exports: [String] = []
    private(set) var imports: [String] = []

    func exportDump(connection: String, schemas: [String], tables: [String],
                    structure: Bool, data: Bool, gzip: Bool) async throws -> MCPExportResult {
        exports.append(connection)
        guard approveWrites else { throw MCPToolError("The user declined the export.") }
        return MCPExportResult(path: "/tmp/shop.sql", bytes: 42)
    }

    func importDump(connection: String, filePath: String) async throws -> MCPImportResult {
        imports.append(filePath)
        guard approveWrites else { throw MCPToolError("The user declined the import.") }
        return MCPImportResult(file: filePath, message: "ok")
    }
}

final class MCPServiceTests: XCTestCase {

    private let writable = MCPConnectionInfo(name: "staging", engine: "PostgreSQL",
                                             database: "shop", canWrite: true, isConnected: true)
    /// Exposed for reading only — MCP write permission withheld.
    private let readOnly = MCPConnectionInfo(name: "prod", engine: "PostgreSQL",
                                             database: "shop", canWrite: false, isConnected: true)

    private func call(_ service: MCPService, tool: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": tool, "arguments": arguments]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let handled = await service.handle(data)
        let responseData = try XCTUnwrap(handled)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (try XCTUnwrap(content.first?["text"] as? String),
                result["isError"] as? Bool ?? false)
    }

    func testInitializeAdvertisesTools() async throws {
        let service = MCPService(source: FakeSource(connections: [writable]))
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let handled = await service.handle(data)
        let response = try XCTUnwrap(handled)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPService.protocolVersion)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
    }

    func testNotificationsGetNoReply() async throws {
        let service = MCPService(source: FakeSource(connections: [writable]))
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized"])
        let response = await service.handle(data)
        XCTAssertNil(response)
    }

    func testToolsListIncludesRunQuery() async throws {
        let service = MCPService(source: FakeSource(connections: [writable]))
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let handled = await service.handle(data)
        let response = try XCTUnwrap(handled)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "run_query" })
        XCTAssertTrue(tools.contains { $0["name"] as? String == "describe_table" })
    }

    func testReadQueryRunsDirectly() async throws {
        let source = FakeSource(connections: [writable])
        let service = MCPService(source: source)
        let (text, isError) = try await call(service, tool: "run_query",
                                             ["connection": "staging", "sql": "SELECT 1"])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("\"rowCount\""))
        let reads = await source.readQueries
        let writes = await source.writeQueries
        XCTAssertEqual(reads, ["SELECT 1"])
        XCTAssertTrue(writes.isEmpty)
    }

    func testWriteGoesThroughApprovalPath() async throws {
        let source = FakeSource(connections: [writable])
        let service = MCPService(source: source)
        _ = try await call(service, tool: "run_query",
                           ["connection": "staging", "sql": "DELETE FROM t WHERE id = 1"])
        let reads = await source.readQueries
        let writes = await source.writeQueries
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(writes.count, 1)      // routed to the approving path, not run directly
    }

    func testWriteRefusedOnReadOnlyConnection() async throws {
        let source = FakeSource(connections: [readOnly])
        let service = MCPService(source: source)
        let (text, isError) = try await call(service, tool: "run_query",
                                             ["connection": "prod", "sql": "DELETE FROM t"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("not permitted to write"))
        let writes = await source.writeQueries
        XCTAssertTrue(writes.isEmpty)        // never even offered for approval
    }

    func testUnknownConnectionIsRefused() async throws {
        let service = MCPService(source: FakeSource(connections: [writable]))
        let (text, isError) = try await call(service, tool: "run_query",
                                             ["connection": "secret", "sql": "SELECT 1"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("Unknown connection"))
    }

    func testMultipleStatementsRefused() async throws {
        let service = MCPService(source: FakeSource(connections: [writable]))
        let (text, isError) = try await call(service, tool: "run_query",
                                             ["connection": "staging", "sql": "SELECT 1; DROP TABLE t"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("single statement"))
    }

    func testSampleTableIsAlwaysRead() async throws {
        let source = FakeSource(connections: [readOnly])   // works even on read-only
        let service = MCPService(source: source)
        let (_, isError) = try await call(service, tool: "sample_table",
                                          ["connection": "prod", "table": "customers", "limit": 5])
        XCTAssertFalse(isError)
        let reads = await source.readQueries
        XCTAssertEqual(reads.first, "SELECT * FROM \"customers\" LIMIT 5")
    }

    func testExplainRejectsWritingStatements() async throws {
        let service = MCPService(source: FakeSource(connections: [writable]))
        let (_, isError) = try await call(service, tool: "explain_query",
                                          ["connection": "staging", "sql": "DELETE FROM t"])
        XCTAssertTrue(isError)
    }

    func testCreateTableGoesThroughApproval() async throws {
        let source = FakeSource(connections: [writable])
        let service = MCPService(source: source)
        _ = try await call(service, tool: "run_query",
                           ["connection": "staging", "sql": "CREATE TABLE t (a int)"])
        let writes = await source.writeQueries
        XCTAssertEqual(writes.count, 1)
    }

    func testExportGoesThroughApprovalPath() async throws {
        let source = FakeSource(connections: [writable])
        let service = MCPService(source: source)
        let (text, isError) = try await call(service, tool: "export_dump", ["connection": "staging"])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("shop.sql"), "unexpected payload: \(text)")
        let exports = await source.exports
        XCTAssertEqual(exports, ["staging"])
    }

    func testExportAllowedOnReadOnlyConnection() async throws {
        // Exporting only reads from the database, so read-only doesn't block it.
        let source = FakeSource(connections: [readOnly])
        let service = MCPService(source: source)
        let (_, isError) = try await call(service, tool: "export_dump", ["connection": "prod"])
        XCTAssertFalse(isError)
    }

    func testImportRefusedOnReadOnlyConnection() async throws {
        let source = FakeSource(connections: [readOnly])
        let service = MCPService(source: source)
        let (text, isError) = try await call(service, tool: "import_dump",
                                             ["connection": "prod", "file": "/tmp/a.sql"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("not permitted to write"))
        let imports = await source.imports
        XCTAssertTrue(imports.isEmpty)   // never even offered for approval
    }

    func testImportGoesThroughApprovalPath() async throws {
        let source = FakeSource(connections: [writable])
        let service = MCPService(source: source)
        let (_, isError) = try await call(service, tool: "import_dump",
                                          ["connection": "staging", "file": "/tmp/a.sql"])
        XCTAssertFalse(isError)
        let imports = await source.imports
        XCTAssertEqual(imports, ["/tmp/a.sql"])
    }

    func testDeclinedImportSurfacesAsError() async throws {
        let source = FakeSource(connections: [writable])
        await source.setApproveWrites(false)
        let service = MCPService(source: source)
        let (text, isError) = try await call(service, tool: "import_dump",
                                             ["connection": "staging", "file": "/tmp/a.sql"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("declined"))
    }

    func testDeclinedWriteSurfacesAsError() async throws {
        let source = FakeSource(connections: [writable])
        await source.setApproveWrites(false)
        let service = MCPService(source: source)
        let (text, isError) = try await call(service, tool: "run_query",
                                             ["connection": "staging", "sql": "UPDATE t SET a = 1"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("declined"))
    }
}

private extension FakeSource {
    func setApproveWrites(_ value: Bool) { approveWrites = value }
}
