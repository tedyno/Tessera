import Foundation

/// Reference to a `ConnectionProfile` in the organizer. A tree node stores only
/// the profile ID; the connection parameters live in `ProfileStore` and secrets
/// in the Keychain.
public struct ConnectionRef: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var profileID: UUID

    public init(id: UUID = UUID(), profileID: UUID) {
        self.id = id
        self.profileID = profileID
    }
}

/// A folder — may contain further folders and connections.
public struct Folder: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var children: [OrganizerNode]
    /// Optional palette color name (e.g. "blue") shown on the folder icon.
    public var color: String?

    public init(id: UUID = UUID(), name: String, children: [OrganizerNode] = [], color: String? = nil) {
        self.id = id
        self.name = name
        self.children = children
        self.color = color
    }
}

/// A project — contains folders and connections.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var children: [OrganizerNode]

    public init(id: UUID = UUID(), name: String, children: [OrganizerNode] = []) {
        self.id = id
        self.name = name
        self.children = children
    }
}

/// A node of the user-defined organizer. The recursive shape maps directly onto
/// SwiftUI's `OutlineGroup` via `children`.
public enum OrganizerNode: Codable, Sendable, Hashable, Identifiable {
    case project(Project)
    case folder(Folder)
    case connection(ConnectionRef)

    public var id: UUID {
        switch self {
        case .project(let p): p.id
        case .folder(let f): f.id
        case .connection(let c): c.id
        }
    }

    /// The node's children, or `nil` for a leaf (connection) — exactly the shape
    /// `OutlineGroup(_:children:)` expects.
    public var children: [OrganizerNode]? {
        switch self {
        case .project(let p): p.children
        case .folder(let f): f.children
        case .connection: nil
        }
    }
}

/// Organizer root: a list of workspaces. Serialized to `organizer.json`.
public struct Workspace: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var children: [OrganizerNode]

    public init(id: UUID = UUID(), name: String, children: [OrganizerNode] = []) {
        self.id = id
        self.name = name
        self.children = children
    }
}

/// The full persisted organizer document.
public struct OrganizerDocument: Codable, Sendable, Hashable {
    public var workspaces: [Workspace]

    public init(workspaces: [Workspace] = []) {
        self.workspaces = workspaces
    }
}
