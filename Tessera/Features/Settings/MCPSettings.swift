import Foundation

/// Settings for the built-in MCP server. The master switch is **off by default** —
/// nothing is served until the user deliberately turns it on, and even then only
/// connections that individually grant MCP access are visible.
enum MCPSettings {
    static let enabledKey = "tessera.mcp.enabled"
    static let portKey = "tessera.mcp.port"

    static let defaultPort = 8787

    /// Master switch. Off unless explicitly enabled.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }   // absent == false
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var port: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            return stored > 0 ? stored : defaultPort
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: portKey) }
    }
}
