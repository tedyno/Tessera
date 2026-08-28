import Foundation

/// Ready-to-paste client configuration for the built-in MCP server.
///
/// Connecting a client is only half the job: every client also decides for itself
/// whether a tool call needs the user's blessing, and it decides that from its own
/// config, not from the read/write permissions set in Tessera. Without the second
/// half, an assistant that has been granted read access still stops and asks before
/// every `list_tables`. So each snippet carries both the server entry and whatever
/// that particular client needs in order to run the safe tools unattended.
///
/// This stays honest because the dangerous tools defend themselves: they are
/// annotated `destructiveHint` for clients that read annotations, and carry
/// `requiresUserInteraction` for Claude Code, which prompts on them regardless of
/// what an allowlist says.
public enum MCPClientConfig {
    public enum Client: String, CaseIterable, Sendable, Identifiable {
        case claudeCode
        case codex
        case generic

        public var id: String { rawValue }

        /// Shown in the settings picker. Not localized: these are product names.
        public var label: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .generic: "Other MCP client"
            }
        }
    }

    /// The MCP server name clients address Tessera by. Claude Code builds its
    /// permission rules out of it (`mcp__tessera__…`), so it has to match
    /// `MCPService.serverName`.
    public static let serverName = MCPService.serverName

    public static func snippet(for client: Client, port: Int, token: String) -> String {
        switch client {
        case .generic: genericSnippet(port: port, token: token)
        case .claudeCode: claudeCodeSnippet(port: port, token: token)
        case .codex: codexSnippet(port: port, token: token)
        }
    }

    // MARK: Per-client snippets

    private static func genericSnippet(port: Int, token: String) -> String {
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "type": "http",
              "url": "\(url(port: port))",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    /// Just the command that registers the server — nothing else, because nothing
    /// else can share a clipboard here. Claude Code keeps MCP servers and permissions
    /// in different files, its settings are strict JSON (so an explanatory `//` line
    /// would break the file), and the permission rule has to be *merged* into an
    /// existing `allow` list rather than pasted over it. The rule is one short token,
    /// so it belongs in the surrounding UI text; the long, token-bearing command is
    /// what actually needs copying.
    private static func claudeCodeSnippet(port: Int, token: String) -> String {
        """
        claude mcp add --transport http \(serverName) \(url(port: port)) \
        --header "Authorization: Bearer \(token)"
        """
    }

    /// A briefing the user pastes to their assistant once, in their own words to it.
    ///
    /// This deliberately does *not* go in the protocol's `instructions` field, which
    /// clients re-send as context on every single turn: none of it is needed until
    /// something actually goes wrong, and paying for it continuously to cover a
    /// first-run snag is a bad trade. Pasted by hand it costs nothing until it helps.
    ///
    /// Written for a model, so it stays in English however the app is localized.
    public static let assistantBriefing = """
        Notes on the Tessera MCP server:

        - It exposes only the databases the user ticked for MCP access in the app. \
        A connection missing from list_connections is deliberately hidden, not broken \
        — do not tell the user something is misconfigured.
        - Approval happens in two independent places, and a refusal from one says \
        nothing about the other. Tessera shows the user a sheet for every write, \
        import and export, quoting the exact SQL or file. The MCP client has its own \
        separate gate, which knows nothing about the permissions set in Tessera.
        - So if calls keep needing approval even though the user granted access in \
        Tessera, it is the client stopping you, not Tessera. In Claude Code the fix \
        is to allow the rule `mcp__\(serverName)` (via /permissions, or permissions.allow \
        in settings.json). Suggest that instead of sending the user back to re-check \
        settings they already set.
        - Allowing the whole server is safe: import_dump, delete_connection and \
        update_connection are marked as always requiring a human, so they keep \
        prompting whatever the allowlist says.
        - "The user declined" means they saw the request and said no. "Another \
        approval is already on screen" means retry shortly.
        """

    /// The permission rule that lets Claude Code call Tessera without prompting.
    /// Allowing the whole server is deliberate: the tools that can destroy data carry
    /// `requiresUserInteraction`, so they ask on every call regardless.
    public static var claudeCodePermissionRule: String { "mcp__\(serverName)" }

    /// Codex reads annotations for its `writes` mode — reads through, writes gated —
    /// which lines up exactly with how Tessera annotates its tools.
    private static func codexSnippet(port: Int, token: String) -> String {
        """
        # ~/.codex/config.toml — the table name takes an underscore; Codex silently
        # ignores the camelCase spelling other clients use.
        [mcp_servers.\(serverName)]
        url = "\(url(port: port))"
        http_headers = { Authorization = "Bearer \(token)" }

        # Reads and exports run unattended; queries that write, dump imports and
        # connection management stop for confirmation.
        default_tools_approval_mode = "writes"
        """
    }

    private static func url(port: Int) -> String { "http://127.0.0.1:\(port)" }
}
