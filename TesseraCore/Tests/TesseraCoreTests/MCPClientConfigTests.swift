import XCTest
@testable import DBKit

/// Enough of an `MCPDataSource` to drive a handshake; the tools are never called.
private actor FakeSource: MCPDataSource {
    let connections: [MCPConnectionInfo]
    init(connections: [MCPConnectionInfo]) { self.connections = connections }
    func listConnections() async -> [MCPConnectionInfo] { connections }
    func connection(named name: String) async -> MCPConnectionInfo? { nil }
    func serverInfo(connection: String) async throws -> [String: String] { [:] }
    func listSchemas(connection: String) async throws -> [String] { [] }
    func listTables(connection: String, schema: String?) async throws -> [MCPTableInfo] { [] }
    func describeTable(connection: String, schema: String?, table: String) async throws -> MCPTableDetail {
        MCPTableDetail(schema: "", table: table, columns: [], indexes: [])
    }
    func search(term: String) async -> MCPSearchResult {
        MCPSearchResult(hits: [], searched: [], skipped: [])
    }
    func runReadQuery(connection: String, sql: String, limit: Int?) async throws -> MCPQueryResult {
        MCPQueryResult(columns: [], textRows: [], truncated: false)
    }
    func runWriteQuery(connection: String, sql: String) async throws -> MCPQueryResult {
        MCPQueryResult(columns: [], textRows: [], truncated: false)
    }
    func exportResult(connection: String, sql: String, format: String,
                      limit: Int?) async throws -> MCPExportResult {
        MCPExportResult(path: "", bytes: 0)
    }
    func exportDump(connection: String, schemas: [String], tables: [String],
                    structure: Bool, data: Bool, gzip: Bool) async throws -> MCPExportResult {
        MCPExportResult(path: "", bytes: 0)
    }
    func importDump(connection: String, filePath: String) async throws -> MCPImportResult {
        MCPImportResult(file: filePath, message: "")
    }
}

/// These snippets are copied straight into a user's config, so a wrong key is worse
/// than no snippet at all — it fails quietly and the user blames Tessera.
final class MCPClientConfigTests: XCTestCase {
    private func snippet(_ client: MCPClientConfig.Client) -> String {
        MCPClientConfig.snippet(for: client, port: 8787, token: "abc123")
    }

    func testEverySnippetCarriesTheLoopbackURLAndToken() {
        for client in MCPClientConfig.Client.allCases {
            let text = snippet(client)
            XCTAssertTrue(text.contains("http://127.0.0.1:8787"), "\(client.label): no URL")
            XCTAssertTrue(text.contains("abc123"), "\(client.label): no token")
        }
    }

    func testGenericSnippetIsValidJSONWithTheServerEntry() throws {
        let data = Data(snippet(.generic).utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = try XCTUnwrap(parsed?["mcpServers"] as? [String: Any])
        let tessera = try XCTUnwrap(servers["tessera"] as? [String: Any])
        XCTAssertEqual(tessera["type"] as? String, "http")
        XCTAssertEqual(tessera["url"] as? String, "http://127.0.0.1:8787")
    }

    /// Claude Code builds its permission rules from the server name, so the rule has
    /// to be `mcp__` plus exactly the name the service advertises.
    func testPermissionRuleMatchesTheAdvertisedServerName() {
        XCTAssertEqual(MCPClientConfig.claudeCodePermissionRule, "mcp__\(MCPService.serverName)")
    }

    /// One runnable command and nothing else. Claude Code's settings are strict JSON,
    /// so a `//` line explaining things would break the file it lands in, and its MCP
    /// servers live somewhere else entirely — a mixed blob is pasteable nowhere.
    func testClaudeCodeSnippetIsOneRunnableCommand() {
        let text = snippet(.claudeCode)
        XCTAssertEqual(text.split(separator: "\n").count, 1, "must be a single line")
        XCTAssertTrue(text.hasPrefix("claude mcp add --transport http \(MCPService.serverName) "))
        for line in text.split(separator: "\n") {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                           "a comment line would be run as a command")
        }
        XCTAssertFalse(text.contains("permissions"), "the rule belongs in the UI text, not here")
    }

    /// `mcpServers` in camelCase is silently ignored by Codex — the classic mistake.
    func testCodexSnippetUsesSnakeCaseTableAndTheWritesApprovalMode() {
        let text = snippet(.codex)
        XCTAssertTrue(text.contains("[mcp_servers.tessera]"))
        XCTAssertFalse(text.contains("mcpServers"))
        XCTAssertTrue(text.contains("default_tools_approval_mode = \"writes\""))
        XCTAssertTrue(text.contains("http_headers"))
    }

    /// The briefing is for the user to paste when they hit trouble. Putting it in the
    /// protocol's `instructions` field would make clients re-send every word of it as
    /// context on every turn, forever, to cover a problem most sessions never have.
    func testBriefingIsNotSentOverTheProtocol() async throws {
        let service = MCPService(source: FakeSource(connections: []))
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let handled = await service.handle(data)
        let response = try XCTUnwrap(handled)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertNil(result["instructions"], "the briefing belongs in the clipboard, not the handshake")
    }

    /// It is only worth pasting if it carries what the user cannot otherwise find out.
    func testBriefingCarriesThePermissionRule() {
        XCTAssertTrue(MCPClientConfig.assistantBriefing
            .contains(MCPClientConfig.claudeCodePermissionRule))
    }

    func testPortIsTakenFromTheSettingsNotHardcoded() {
        let text = MCPClientConfig.snippet(for: .codex, port: 9999, token: "t")
        XCTAssertTrue(text.contains("http://127.0.0.1:9999"))
        XCTAssertFalse(text.contains("8787"))
    }
}
