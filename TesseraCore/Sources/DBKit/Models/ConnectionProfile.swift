import Foundation

/// Supported database engines.
public enum DatabaseKind: String, Codable, Sendable, CaseIterable, Hashable {
    case postgres
    case mysql

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        }
    }
}

/// Connection TLS mode (naming follows libpq / MySQL `sslmode`).
public enum TLSMode: String, Codable, Sendable, CaseIterable, Hashable {
    case disable
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"
}

/// SSH authentication method for the tunnel.
public enum SSHAuthMethod: Codable, Sendable, Hashable {
    case password
    case privateKey(path: String)
}

/// SSH tunnel configuration (local port forwarding in front of the DB connection).
public struct SSHConfig: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod

    public init(host: String, port: Int = 22, username: String, authMethod: SSHAuthMethod) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }
}

/// Persisted connection profile. Holds **no secrets** — the password and SSH
/// passphrase live in the Keychain under `keychainAccount`.
public struct ConnectionProfile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var tlsMode: TLSMode
    public var ssh: SSHConfig?
    /// Optional so older profiles decode; use `isReadOnly`.
    public var readOnly: Bool?
    /// Optional palette color name for the connection dot.
    public var color: String?
    /// Opt-in: expose this connection over the built-in MCP server. Optional so
    /// older profiles decode; use `allowsMCPAccess`. Off unless deliberately enabled.
    public var mcpAccess: Bool?

    /// Stable Keychain key (service = bundle ID, account = this value).
    public var keychainAccount: String { id.uuidString }

    /// When true, the app warns before writing (e.g. committing cell edits), and MCP
    /// may only read from it.
    public var isReadOnly: Bool { readOnly ?? false }

    /// Whether an MCP client may see and query this connection at all.
    public var allowsMCPAccess: Bool { mcpAccess ?? false }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: DatabaseKind,
        host: String,
        port: Int? = nil,
        database: String,
        username: String,
        tlsMode: TLSMode = .prefer,
        ssh: SSHConfig? = nil,
        readOnly: Bool = false,
        color: String? = nil,
        mcpAccess: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.database = database
        self.username = username
        self.tlsMode = tlsMode
        self.ssh = ssh
        self.readOnly = readOnly ? true : nil
        self.color = color
        self.mcpAccess = mcpAccess ? true : nil
    }
}

/// Secrets loaded from the Keychain at runtime. Deliberately **not `Codable`** so
/// they can never be serialized to disk.
public struct Secrets: Sendable {
    public var databasePassword: String?
    public var sshPassword: String?
    public var sshPassphrase: String?

    public init(
        databasePassword: String? = nil,
        sshPassword: String? = nil,
        sshPassphrase: String? = nil
    ) {
        self.databasePassword = databasePassword
        self.sshPassword = sshPassword
        self.sshPassphrase = sshPassphrase
    }
}

/// The actual TCP target the driver connects to. With an active SSH tunnel this
/// points at the local end of the tunnel (127.0.0.1:<randomPort>); otherwise
/// directly at `ConnectionProfile.host`/`port`.
public struct NetworkEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}
