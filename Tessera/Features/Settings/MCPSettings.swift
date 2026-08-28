import DBKit
import Foundation
import Security

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

    static let tokenKey = "tessera.mcp.token"

    /// Bearer token every client must send. Generated on first use. Stored in the
    /// app's defaults rather than the Keychain deliberately: it must be readable at
    /// launch without prompting, and it only guards a loopback socket that any
    /// process running as this user could reach anyway. Its real job is stopping a
    /// web page from driving the server.
    static var token: String {
        if let existing = UserDefaults.standard.string(forKey: tokenKey), !existing.isEmpty {
            return existing
        }
        let fresh = generateToken()
        UserDefaults.standard.set(fresh, forKey: tokenKey)
        return fresh
    }

    @discardableResult
    static func regenerateToken() -> String {
        let fresh = generateToken()
        UserDefaults.standard.set(fresh, forKey: tokenKey)
        return fresh
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A ready-to-paste client entry, including whatever that client needs in order
    /// to run the safe tools without asking. Built in `TesseraCore`.
    static func clientConfigSnippet(for client: MCPClientConfig.Client) -> String {
        MCPClientConfig.snippet(for: client, port: port, token: token)
    }
}
