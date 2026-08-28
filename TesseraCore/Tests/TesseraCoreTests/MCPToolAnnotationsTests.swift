import XCTest
@testable import DBKit

/// The annotations are what stops a client asking before every `list_tables`, and
/// what keeps it asking before an `import_dump`. Getting one wrong is silent — the
/// tool still works, it just stops being gated the way the user expects — so the
/// whole catalog is pinned here.
final class MCPToolAnnotationsTests: XCTestCase {
    /// Tools a client may run unattended: they change nothing, or they only produce
    /// a file in a folder Tessera chose.
    private static let readOnly: Set<String> = [
        "list_connections", "server_info", "list_schemas", "list_tables",
        "describe_table", "search", "sample_table", "explain_query", "list_organizer",
        "export_dump", "export_result", "export_diagram",
    ]

    /// Tools that can overwrite or destroy what is already there.
    private static let destructive: Set<String> = [
        "run_query", "import_dump", "update_connection", "delete_connection",
    ]

    /// The subset Claude Code must prompt for even in auto mode. `run_query` is
    /// deliberately absent: it is the tool used for ordinary SELECTs, and its writes
    /// are already gated by Tessera's own approval sheet.
    private static let alwaysAsk: Set<String> = [
        "import_dump", "update_connection", "delete_connection",
    ]

    private func tools() throws -> [[String: JSONValue]] {
        guard case .array(let entries) = MCPTools.catalog else {
            XCTFail("catalog is not an array")
            return []
        }
        return entries.compactMap(\.objectValue)
    }

    func testEveryToolCarriesAnnotations() throws {
        for tool in try tools() {
            let name = tool["name"]?.stringValue ?? "?"
            guard let annotations = tool["annotations"]?.objectValue else {
                XCTFail("\(name) has no annotations"); continue
            }
            XCTAssertNotNil(annotations["readOnlyHint"]?.boolValue, "\(name): no readOnlyHint")
            XCTAssertEqual(annotations["openWorldHint"]?.boolValue, false,
                           "\(name): Tessera only ever talks to configured databases")
        }
    }

    func testReadOnlyHintMatchesWhatTheToolActuallyDoes() throws {
        var seen: Set<String> = []
        for tool in try tools() {
            let name = tool["name"]?.stringValue ?? "?"
            seen.insert(name)
            let isReadOnly = tool["annotations"]?.objectValue?["readOnlyHint"]?.boolValue
            XCTAssertEqual(isReadOnly, Self.readOnly.contains(name),
                           "\(name): readOnlyHint disagrees with the expected classification")
        }
        XCTAssertTrue(Self.readOnly.isSubset(of: seen), "a tool in the expected set is missing")
    }

    func testDestructiveHintIsSetOnlyWhereDataCanBeLost() throws {
        for tool in try tools() {
            let name = tool["name"]?.stringValue ?? "?"
            let annotations = tool["annotations"]?.objectValue ?? [:]
            if Self.readOnly.contains(name) {
                // Meaningless on a read-only tool, so it is left out entirely.
                XCTAssertNil(annotations["destructiveHint"], "\(name): hint has no meaning here")
            } else {
                XCTAssertEqual(annotations["destructiveHint"]?.boolValue,
                               Self.destructive.contains(name), "\(name): wrong destructiveHint")
            }
        }
    }

    func testOnlyDataLosingToolsDemandUserInteraction() throws {
        for tool in try tools() {
            let name = tool["name"]?.stringValue ?? "?"
            let flag = tool["_meta"]?.objectValue?["anthropic/requiresUserInteraction"]?.boolValue
            XCTAssertEqual(flag ?? false, Self.alwaysAsk.contains(name),
                           "\(name): requiresUserInteraction disagrees with the expected set")
        }
    }

    /// The briefing tells the assistant that allowing `mcp__tessera` wholesale is
    /// safe, and names the tools that keep prompting anyway. Add a fourth such tool
    /// without updating that text and the claim quietly stops being true.
    func testBriefingNamesEveryToolItPromisesWillKeepAsking() throws {
        for tool in try tools() {
            let name = tool["name"]?.stringValue ?? "?"
            let asks = tool["_meta"]?.objectValue?["anthropic/requiresUserInteraction"]?.boolValue ?? false
            guard asks else { continue }
            XCTAssertTrue(MCPClientConfig.assistantBriefing.contains(name),
                          "\(name) always prompts, but the briefing never says so")
        }
    }

    /// Telling users they can allow the whole server is only honest while every
    /// destructive tool forces a prompt of its own. `run_query` is the one exception,
    /// and only because Tessera gates its writes itself in `MCPBridge` — a new
    /// destructive tool added without the flag has no such cover, and trips this.
    func testDestructiveToolsForcePromptExceptTheOneTesseraGatesItself() throws {
        var unguarded: Set<String> = []
        for tool in try tools() {
            let name = tool["name"]?.stringValue ?? "?"
            let destructive = tool["annotations"]?.objectValue?["destructiveHint"]?.boolValue ?? false
            let asks = tool["_meta"]?.objectValue?["anthropic/requiresUserInteraction"]?.boolValue ?? false
            if destructive, !asks { unguarded.insert(name) }
        }
        XCTAssertEqual(unguarded, ["run_query"])
    }
}
