import Foundation
import DBKit

/// What importing a `ConnectionBundle` would do — computed up front so it can be
/// shown before anything changes, then applied as is.
///
/// Import only ever **adds**. Nothing already in the organizer is renamed, moved,
/// recolored or overwritten; a connection that is already here is skipped, not
/// updated.
public struct ConnectionImportPlan: Sendable {
    /// The organizer with the imported nodes merged in.
    public var organizer: OrganizerDocument
    /// Profiles to add, each with the secrets to store for it.
    public var added: [(profile: ConnectionProfile, secrets: Secrets)]
    /// Profiles left out because the same connection already exists.
    public var skipped: [ConnectionProfile]

    /// Merges `bundle` into `organizer`. A bundled profile counts as already present
    /// when a profile with its id exists (imported before, or exported from this very
    /// Tessera) or when one with the same name and target does (e.g. the sample
    /// connection every fresh install starts with).
    public init(bundle: ConnectionBundle, into organizer: OrganizerDocument,
                existingProfiles: [ConnectionProfile]) {
        var skipped: [ConnectionProfile] = []
        var added: [(profile: ConnectionProfile, secrets: Secrets)] = []
        var seen = Set<UUID>()
        for profile in bundle.profiles where seen.insert(profile.id).inserted {
            if existingProfiles.contains(where: { Self.isSameConnection($0, profile) }) {
                skipped.append(profile)
            } else {
                added.append((profile, bundle.secrets(for: profile.id)))
            }
        }

        var merger = Merger(document: organizer, importing: Set(added.map(\.profile.id)))
        merger.merge(bundle.organizer)
        // A bundled profile the bundled tree never mentions would otherwise be added
        // yet invisible; it goes loose, at the top.
        for (profile, _) in added where !merger.placed.contains(profile.id) {
            merger.document.looseConnections.append(
                .connection(ConnectionRef(id: merger.freshID(UUID()), profileID: profile.id)))
        }

        self.organizer = merger.document
        self.added = added
        self.skipped = skipped
    }

    static func isSameConnection(_ a: ConnectionProfile, _ b: ConnectionProfile) -> Bool {
        if a.id == b.id { return true }
        return a.name == b.name && a.kind == b.kind && a.host == b.host && a.port == b.port
            && a.database == b.database && a.username == b.username
    }
}

/// Walks the bundled tree and grafts it onto the existing one. Containers match an
/// existing one by id, then by kind and name, and are merged into rather than
/// duplicated; everything else is appended.
private struct Merger {
    var document: OrganizerDocument
    let importing: Set<UUID>
    /// Profiles that got a node somewhere.
    var placed = Set<UUID>()
    /// Every node and workspace id in use, so nothing added can collide.
    private var usedIDs: Set<UUID>

    init(document: OrganizerDocument, importing: Set<UUID>) {
        self.document = document
        self.importing = importing
        var ids = Set(document.workspaces.map(\.id))
        Self.collect(document.looseConnections, into: &ids)
        for workspace in document.workspaces { Self.collect(workspace.children, into: &ids) }
        usedIDs = ids
    }

    private static func collect(_ nodes: [OrganizerNode], into ids: inout Set<UUID>) {
        for node in nodes {
            ids.insert(node.id)
            collect(node.children ?? [], into: &ids)
        }
    }

    /// `id` if it is still free, otherwise a new one; either way it is now taken.
    mutating func freshID(_ id: UUID) -> UUID {
        let chosen = usedIDs.contains(id) ? UUID() : id
        usedIDs.insert(chosen)
        return chosen
    }

    mutating func merge(_ bundled: OrganizerDocument) {
        document.looseConnections = mergeChildren(
            bundled.looseConnections.filter { if case .connection = $0 { true } else { false } },
            into: document.looseConnections)

        for workspace in bundled.workspaces {
            if let index = document.workspaces.firstIndex(where: { $0.id == workspace.id })
                ?? document.workspaces.firstIndex(where: { $0.name == workspace.name }) {
                document.workspaces[index].children =
                    mergeChildren(workspace.children, into: document.workspaces[index].children)
            } else if let children = graft(workspace.children) {
                document.workspaces.append(
                    Workspace(id: freshID(workspace.id), name: workspace.name, children: children))
            }
        }
    }

    /// `target` with `source` merged in; existing nodes keep their place and content.
    private mutating func mergeChildren(_ source: [OrganizerNode],
                                        into target: [OrganizerNode]) -> [OrganizerNode] {
        var result = target
        for node in source {
            switch node {
            case .connection(let ref):
                guard importing.contains(ref.profileID), !placed.contains(ref.profileID) else { continue }
                placed.insert(ref.profileID)
                result.append(.connection(ConnectionRef(id: freshID(ref.id), profileID: ref.profileID)))
            case .project, .folder:
                if let index = result.firstIndex(where: { Self.matches($0, node) }) {
                    result[index].setChildren(mergeChildren(node.children ?? [], into: result[index].children ?? []))
                } else if let grafted = graftNode(node) {
                    result.append(grafted)
                }
            }
        }
        return result
    }

    private static func matches(_ existing: OrganizerNode, _ incoming: OrganizerNode) -> Bool {
        if existing.id == incoming.id { return existing.isContainer }
        switch (existing, incoming) {
        case (.project(let a), .project(let b)): return a.name == b.name
        case (.folder(let a), .folder(let b)): return a.name == b.name
        default: return false
        }
    }

    /// A new copy of `nodes` holding only what is being imported, or nil when the
    /// source had connections but none of them made it (an empty shell of a folder
    /// whose connections were all skipped is noise). A source that was already empty
    /// is kept: an empty folder is still organization someone made.
    private mutating func graft(_ nodes: [OrganizerNode]) -> [OrganizerNode]? {
        let out = nodes.compactMap { graftNode($0) }
        return out.isEmpty && !nodes.isEmpty ? nil : out
    }

    private mutating func graftNode(_ node: OrganizerNode) -> OrganizerNode? {
        switch node {
        case .connection(let ref):
            guard importing.contains(ref.profileID), !placed.contains(ref.profileID) else { return nil }
            placed.insert(ref.profileID)
            return .connection(ConnectionRef(id: freshID(ref.id), profileID: ref.profileID))
        case .project(let project):
            guard let children = graft(project.children) else { return nil }
            return .project(Project(id: freshID(project.id), name: project.name, children: children))
        case .folder(let folder):
            guard let children = graft(folder.children) else { return nil }
            return .folder(Folder(id: freshID(folder.id), name: folder.name, children: children,
                                  color: folder.color))
        }
    }
}
