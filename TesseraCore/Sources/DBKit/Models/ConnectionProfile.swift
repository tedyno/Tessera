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
    /// A `Host` alias from `~/.ssh/config`. When set, the hostname, user, port, and
    /// key are read from that file at connect time and the fields above are only
    /// fallbacks — so editing `~/.ssh/config` takes effect without touching Tessera.
    public var configAlias: String?

    public init(host: String, port: Int = 22, username: String, authMethod: SSHAuthMethod,
                configAlias: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.configAlias = configAlias
    }

    /// True when this tunnel is driven by a `~/.ssh/config` alias.
    public var usesConfigAlias: Bool { !(configAlias ?? "").isEmpty }
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
    /// Opt-in: let MCP clients read from this connection. Optional so older profiles
    /// decode; use `allowsMCPRead`. Off unless deliberately enabled.
    public var mcpRead: Bool?
    /// Opt-in: let MCP clients write (always with approval). Capped by `readOnly`.
    public var mcpWrite: Bool?
    /// Superseded by `mcpRead`; kept so profiles written by earlier builds decode.
    public var mcpAccess: Bool?
    /// Opt-in: run MCP writes on this connection without asking each time. Deliberately
    /// separate from `mcpWrite` so approval is only ever dropped on purpose.
    public var mcpWriteWithoutApproval: Bool?

    /// Stable Keychain key (service = bundle ID, account = this value).
    public var keychainAccount: String { id.uuidString }

    /// When true, the app warns before writing (e.g. committing cell edits), and MCP
    /// may only read from it.
    public var isReadOnly: Bool { readOnly ?? false }

    /// Whether an MCP client may see and read this connection at all.
    public var allowsMCPRead: Bool { mcpRead ?? mcpAccess ?? false }

    /// Whether MCP may run writing statements (still approved by the user each time).
    /// A read-only connection is a hard ceiling: MCP can never exceed it, and writing
    /// without reading makes no sense, so read is required too.
    public var allowsMCPWrite: Bool { allowsMCPRead && (mcpWrite ?? false) && !isReadOnly }

    /// Whether MCP writes skip the approval prompt on this connection. Requires write
    /// access, so a read-only connection can never reach it.
    public var allowsMCPWriteWithoutApproval: Bool {
        allowsMCPWrite && (mcpWriteWithoutApproval ?? false)
    }

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
        mcpRead: Bool = false,
        mcpWrite: Bool = false,
        mcpWriteWithoutApproval: Bool = false
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
        self.mcpRead = mcpRead ? true : nil
        self.mcpWrite = mcpWrite ? true : nil
        self.mcpWriteWithoutApproval = mcpWriteWithoutApproval ? true : nil
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
