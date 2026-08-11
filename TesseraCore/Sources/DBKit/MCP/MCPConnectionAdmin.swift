import Foundation

/// A connection an MCP client asked to create.
public struct MCPConnectionSpec: Codable, Sendable, Equatable {
    public var name: String
    public var engine: String
    public var host: String
    public var port: Int?
    public var database: String
    public var user: String
    /// Only ever accepted while creating; there is no way to change it later.
    public var password: String?
    public var tls: String?
    public var parentID: String?
    public var readOnly: Bool?
    /// A `Host` alias from `~/.ssh/config` to tunnel through. Everything else about
    /// the tunnel (hostname, user, port, key) is resolved from that file at connect
    /// time, so this is all a client needs for a host the user already has set up.
    public var sshAlias: String?
    /// Explicit tunnel details, for a host that isn't in `~/.ssh/config`.
    public var sshHost: String?
    public var sshPort: Int?
    public var sshUser: String?
    public var sshKeyPath: String?

    /// The tunnel this spec describes, or nil when it asks for a direct connection.
    public var sshConfig: SSHConfig? {
        let alias = sshAlias?.trimmingCharacters(in: .whitespaces)
        let hasAlias = !(alias ?? "").isEmpty
        guard hasAlias || !(sshHost ?? "").isEmpty else { return nil }
        return SSHConfig(
            host: sshHost ?? "",
            port: sshPort ?? 22,
            username: sshUser ?? "",
            // A key path is the norm here; without one the tunnel falls back to a
            // password the user is asked for, exactly as a manually made profile would.
            authMethod: sshKeyPath.map { SSHAuthMethod.privateKey(path: $0) } ?? .privateKey(path: ""),
            configAlias: hasAlias ? alias : nil)
    }

    public init(name: String, engine: String, host: String, port: Int? = nil, database: String,
                user: String, password: String? = nil, tls: String? = nil,
                parentID: String? = nil, readOnly: Bool? = nil,
                sshAlias: String? = nil, sshHost: String? = nil, sshPort: Int? = nil,
                sshUser: String? = nil, sshKeyPath: String? = nil) {
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.tls = tls
        self.parentID = parentID
        self.readOnly = readOnly
        self.sshAlias = sshAlias
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUser = sshUser
        self.sshKeyPath = sshKeyPath
    }
}

/// The fields an MCP client may change on an existing connection. Deliberately has
/// no password and no MCP-access flags.
public struct MCPConnectionChanges: Codable, Sendable, Equatable {
    public var name: String?
    public var host: String?
    public var port: Int?
    public var database: String?
    public var user: String?
    public var tls: String?
    public var readOnly: Bool?
    public var color: String?

    public init(name: String? = nil, host: String? = nil, port: Int? = nil, database: String? = nil,
                user: String? = nil, tls: String? = nil, readOnly: Bool? = nil, color: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.tls = tls
        self.readOnly = readOnly
        self.color = color
    }
}

public struct MCPConnectionSummary: Codable, Sendable, Equatable {
    public var connectionID: String
    public var name: String
    /// Workspace → … → folder breadcrumb the connection now sits in.
    public var path: [String]
    /// Anything the user should know about what the change implied.
    public var note: String?

    public init(connectionID: String, name: String, path: [String], note: String? = nil) {
        self.connectionID = connectionID
        self.name = name
        self.path = path
        self.note = note
    }
}

/// One node of the connection organizer, as MCP sees it.
public struct MCPOrganizerNode: Codable, Sendable, Equatable {
    public var id: String
    /// `workspace`, `project`, `folder`, or `connection`.
    public var kind: String
    public var name: String
    public var children: [MCPOrganizerNode]?
    public var connectionID: String?
    public var engine: String?
    public var host: String?
    public var database: String?
    public var user: String?
    public var readOnly: Bool?
    /// `none`, `read`, `write`, or `write-without-approval`.
    public var mcpAccess: String?

    public init(id: String, kind: String, name: String, children: [MCPOrganizerNode]? = nil,
                connectionID: String? = nil, engine: String? = nil, host: String? = nil,
                database: String? = nil, user: String? = nil, readOnly: Bool? = nil,
                mcpAccess: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.children = children
        self.connectionID = connectionID
        self.engine = engine
        self.host = host
        self.database = database
        self.user = user
        self.readOnly = readOnly
        self.mcpAccess = mcpAccess
    }
}

/// Rules that keep connection management safe to run without asking the user.
///
/// Two things must hold no matter what a client sends:
/// * a client can never grant itself MCP access — those flags are the user's alone;
/// * a stored password must never follow a connection to a different server, so a
///   change of target invalidates the secrets rather than reusing them.
public enum MCPConnectionPolicy {
    /// Builds a profile for a newly created connection. MCP access is always off:
    /// the client cannot hand itself the keys to what it just made.
    public static func makeProfile(_ spec: MCPConnectionSpec) throws -> ConnectionProfile {
        let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MCPToolError("A connection needs a name.") }
        guard let kind = DatabaseKind(rawValue: spec.engine.lowercased()) else {
            throw MCPToolError("Unknown engine “\(spec.engine)”. Use postgres, mysql, mariadb, sqlite or redis.")
        }
        let host = spec.host.trimmingCharacters(in: .whitespacesAndNewlines)
        var database = spec.database
        guard !database.isEmpty else {
            throw MCPToolError(kind.isFileBased ? "A SQLite connection needs a file path in “database”."
                                                : "A connection needs a database.")
        }
        if kind.isFileBased {
            // The driver opens the path verbatim, so resolve ~ here and refuse a
            // relative path — SQLITE_OPEN_CREATE would silently plant the file
            // wherever the app's working directory happens to be.
            database = (database as NSString).expandingTildeInPath
            guard database.hasPrefix("/") else {
                throw MCPToolError("The SQLite file path must be absolute (or start with ~).")
            }
        } else {
            guard !host.isEmpty else { throw MCPToolError("A connection needs a host.") }
            // Redis authenticates with a password alone (or an optional ACL user).
            guard !spec.user.isEmpty || kind.isKeyValue
            else { throw MCPToolError("A connection needs a user.") }
        }

        return ConnectionProfile(
            name: name, kind: kind, host: host, port: spec.port, database: database,
            username: spec.user, tlsMode: tlsMode(spec.tls),
            // A file on disk has no tunnel to ride — silently attaching one would
            // make open() try SSH to an empty host instead of opening the file.
            ssh: kind.isFileBased ? nil : spec.sshConfig,
            readOnly: spec.readOnly ?? false)
        // mcpRead / mcpWrite / mcpWriteWithoutApproval deliberately left at their
        // defaults (off) — only the user turns those on, in the app.
    }

    /// Builds a copy of an existing profile for duplication. The copy gets a fresh id
    /// (its own Keychain account and sessions) and MCP access forced off: duplicating
    /// over MCP must never carry the original's access flags to the copy, or a client
    /// could clone its way into a connection the user only ever meant to use by hand.
    public static func duplicateProfile(_ original: ConnectionProfile, name: String?) -> ConnectionProfile {
        var copy = original
        copy.id = UUID()
        copy.mcpRead = nil
        copy.mcpWrite = nil
        copy.mcpWriteWithoutApproval = nil
        copy.mcpAccess = nil
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            copy.name = trimmed
        }
        return copy
    }

    /// Applies changes to an existing profile. Everything the client may not touch —
    /// the id, the MCP flags, the SSH settings — is carried over untouched.
    public static func apply(_ changes: MCPConnectionChanges,
                             to profile: ConnectionProfile) throws -> ConnectionProfile {
        var result = profile
        if let name = changes.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MCPToolError("A connection needs a name.") }
            result.name = trimmed
        }
        if let host = changes.host {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MCPToolError("A connection needs a host.") }
            result.host = trimmed
        }
        if let port = changes.port { result.port = port }
        if let database = changes.database {
            guard !database.isEmpty else { throw MCPToolError("A connection needs a database.") }
            result.database = database
        }
        if let user = changes.user {
            guard !user.isEmpty else { throw MCPToolError("A connection needs a user.") }
            result.username = user
        }
        if let tls = changes.tls { result.tlsMode = tlsMode(tls) }
        if let readOnly = changes.readOnly { result.readOnly = readOnly ? true : nil }
        if let color = changes.color { result.color = color.isEmpty ? nil : color }

        // Belt and braces: whatever came in, the access flags stay as the user left them.
        result.mcpRead = profile.mcpRead
        result.mcpWrite = profile.mcpWrite
        result.mcpWriteWithoutApproval = profile.mcpWriteWithoutApproval
        result.mcpAccess = profile.mcpAccess
        return result
    }

    /// True when the edit points the connection at a different server or account, in
    /// which case the stored secrets must be dropped instead of being sent there.
    public static func retargets(from before: ConnectionProfile, to after: ConnectionProfile) -> Bool {
        before.host != after.host
            || before.port != after.port
            || before.database != after.database
            || before.username != after.username
            || before.ssh != after.ssh
    }

    private static func tlsMode(_ raw: String?) -> TLSMode {
        guard let raw else { return .prefer }
        return TLSMode(rawValue: raw.lowercased()) ?? .prefer
    }

    /// How a profile's MCP access reads in the organizer listing.
    public static func accessLabel(_ profile: ConnectionProfile) -> String {
        if profile.allowsMCPWriteWithoutApproval { return "write-without-approval" }
        if profile.allowsMCPWrite { return "write" }
        if profile.allowsMCPRead { return "read" }
        return "none"
    }
}
