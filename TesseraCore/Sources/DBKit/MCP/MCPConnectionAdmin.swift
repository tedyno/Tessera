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

    public init(name: String, engine: String, host: String, port: Int? = nil, database: String,
                user: String, password: String? = nil, tls: String? = nil,
                parentID: String? = nil, readOnly: Bool? = nil) {
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
            throw MCPToolError("Unknown engine “\(spec.engine)”. Use postgres or mysql.")
        }
        let host = spec.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw MCPToolError("A connection needs a host.") }
        guard !spec.database.isEmpty else { throw MCPToolError("A connection needs a database.") }
        guard !spec.user.isEmpty else { throw MCPToolError("A connection needs a user.") }

        return ConnectionProfile(
            name: name, kind: kind, host: host, port: spec.port, database: spec.database,
            username: spec.user, tlsMode: tlsMode(spec.tls), ssh: nil,
            readOnly: spec.readOnly ?? false)
        // mcpRead / mcpWrite / mcpWriteWithoutApproval deliberately left at their
        // defaults (off) — only the user turns those on, in the app.
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
