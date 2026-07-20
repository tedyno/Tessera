import Foundation
import DBKit
import DBPersistence

/// Connection management over MCP. These run without an approval prompt, which is
/// only safe because of two invariants enforced here and in `MCPConnectionPolicy`:
///
/// * a client can never grant itself MCP access — the flags are copied from what the
///   user set and are off on anything it creates;
/// * a stored password never follows a connection to a different server — retargeting
///   an existing connection discards its secrets instead.
///
/// Deletion is undoable: profiles go to a small trash (Keychain entry intact) and are
/// only really destroyed when the trash overflows.
extension MCPBridge {

    // MARK: Reading the tree

    func organizer() async -> [MCPOrganizerNode] {
        // Connections outside any workspace come first, matching the sidebar.
        app.connections.organizer.looseConnections.map(node(from:))
            + app.connections.organizer.workspaces.map { workspace in
                MCPOrganizerNode(id: workspace.id.uuidString, kind: "workspace", name: workspace.name,
                                 children: workspace.children.map(node(from:)))
            }
    }

    private func node(from node: OrganizerNode) -> MCPOrganizerNode {
        switch node {
        case .project(let project):
            return MCPOrganizerNode(id: project.id.uuidString, kind: "project", name: project.name,
                                    children: project.children.map(self.node(from:)))
        case .folder(let folder):
            return MCPOrganizerNode(id: folder.id.uuidString, kind: "folder", name: folder.name,
                                    children: folder.children.map(self.node(from:)))
        case .connection(let ref):
            guard let profile = app.connections.profile(id: ref.profileID) else {
                return MCPOrganizerNode(id: ref.id.uuidString, kind: "connection",
                                        name: "(missing profile)")
            }
            return MCPOrganizerNode(
                id: ref.id.uuidString, kind: "connection", name: profile.name,
                connectionID: profile.id.uuidString, engine: profile.kind.rawValue,
                host: profile.host, database: profile.database, user: profile.username,
                readOnly: profile.isReadOnly,
                mcpAccess: MCPConnectionPolicy.accessLabel(profile))
        }
    }

    // MARK: Mutations

    func createConnection(_ spec: MCPConnectionSpec) async throws -> MCPConnectionSummary {
        let profile = try MCPConnectionPolicy.makeProfile(spec)
        let parent = spec.parentID.flatMap(UUID.init(uuidString:))
        if let parent, !containerExists(parent) {
            throw MCPToolError("No workspace, project or folder with id \(parent.uuidString).")
        }
        // A password is accepted only here, on the way to the Keychain.
        let secrets = Secrets(databasePassword: spec.password)
        app.connections.addConnection(profile, secrets: secrets, into: parent)
        let tunnel = profile.ssh.map { " via SSH \($0.configAlias ?? $0.host)" } ?? ""
        audit("create_connection", profile.name,
              "\(profile.kind.rawValue) \(profile.username)@\(profile.host):\(profile.port)/\(profile.database)\(tunnel)")
        return summary(profile, note: spec.password == nil
                       ? String(localized: "No password stored — Tessera will ask on first connect.")
                       : nil)
    }

    func updateConnection(id: String, changes: MCPConnectionChanges) async throws -> MCPConnectionSummary {
        let profile = try existingProfile(id)
        let updated = try MCPConnectionPolicy.apply(changes, to: profile)

        // Pointing a connection at a new server must not take the old password with
        // it — that would let an edit alone hand the credentials to another host.
        let retargeted = MCPConnectionPolicy.retargets(from: profile, to: updated)
        let secrets = retargeted ? Secrets() : app.connections.secrets(for: profile)
        app.connections.updateConnection(updated, secrets: secrets)
        audit("update_connection", updated.name,
              retargeted
              ? "retargeted to \(updated.username)@\(updated.host):\(updated.port)/\(updated.database) — stored password discarded"
              : "edited")

        return summary(updated, note: retargeted
                       ? String(localized: "The target changed, so the stored password was discarded; Tessera will ask for it on the next connect.")
                       : nil)
    }

    func moveConnection(id: String, parentID: String, index: Int?) async throws -> MCPConnectionSummary {
        let profile = try existingProfile(id)
        guard let parent = UUID(uuidString: parentID), containerExists(parent) else {
            throw MCPToolError("No workspace, project or folder with id \(parentID).")
        }
        guard let nodeID = app.connections.firstNodeID(forProfile: profile.id) else {
            throw MCPToolError("“\(profile.name)” is not in the tree.")
        }
        guard app.connections.move(nodeID: nodeID, toParent: parent, at: index) else {
            throw MCPToolError("Could not move “\(profile.name)” there.")
        }
        audit("move_connection", profile.name,
              app.connections.path(forProfile: profile.id).joined(separator: " / "))
        return summary(profile)
    }

    func createContainer(name: String, kind: String, parentID: String?) async throws -> MCPOrganizerNode {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPToolError("A container needs a name.") }
        let parent = parentID.flatMap(UUID.init(uuidString:))
        if let parent, !containerExists(parent) {
            throw MCPToolError("No workspace, project or folder with id \(parent.uuidString).")
        }

        let before = Set(allContainerIDs())
        switch kind.lowercased() {
        case "workspace": app.connections.addWorkspace(name: trimmed)
        case "project": app.connections.addProject(name: trimmed, into: parent)
        case "folder": app.connections.addFolder(name: trimmed, into: parent)
        default: throw MCPToolError("Unknown kind “\(kind)”. Use workspace, project or folder.")
        }
        let created = allContainerIDs().first { !before.contains($0) }
        audit("create_container", trimmed, kind.lowercased())
        return MCPOrganizerNode(id: created?.uuidString ?? "", kind: kind.lowercased(), name: trimmed)
    }

    // MARK: Delete / restore

    func deleteConnection(id: String) async throws -> MCPConnectionSummary {
        let profile = try existingProfile(id)
        let parent = app.connections.firstNodeID(forProfile: profile.id)
            .flatMap { app.connections.organizer.location(of: $0)?.parent }
        // Keep the Keychain entry while it sits in the trash, so a restore is complete.
        app.mcpTrash.put(profile: profile, parentID: parent, connections: app.connections)
        audit("delete_connection", profile.name, "moved to trash")
        return summary(profile, note: String(localized: "Moved to the trash — restore_connection puts it back."))
    }

    func restoreConnection(id: String) async throws -> MCPConnectionSummary {
        guard let uuid = UUID(uuidString: id) else { throw MCPToolError("“\(id)” is not a connection id.") }
        guard let restored = app.mcpTrash.restore(id: uuid, connections: app.connections) else {
            throw MCPToolError("Nothing with id \(id) is in the trash.")
        }
        audit("restore_connection", restored.name, "restored from trash")
        return summary(restored)
    }

    // MARK: Helpers

    /// These tools never prompt, so the audit log is the only record that they ran.
    private func audit(_ tool: String, _ connection: String, _ detail: String) {
        app.mcpAudit.record(tool: tool, connection: connection, detail: detail,
                            outcome: "done (no approval required)")
    }

    private func existingProfile(_ id: String) throws -> ConnectionProfile {
        guard let uuid = UUID(uuidString: id) else {
            throw MCPToolError("“\(id)” is not a connection id — use the ids from list_organizer.")
        }
        guard let profile = app.connections.profile(id: uuid) else {
            throw MCPToolError("No connection with id \(id).")
        }
        return profile
    }

    private func summary(_ profile: ConnectionProfile, note: String? = nil) -> MCPConnectionSummary {
        MCPConnectionSummary(connectionID: profile.id.uuidString, name: profile.name,
                             path: app.connections.path(forProfile: profile.id), note: note)
    }

    private func containerExists(_ id: UUID) -> Bool { allContainerIDs().contains(id) }

    /// Ids of everything a connection can be filed under.
    private func allContainerIDs() -> [UUID] {
        var result: [UUID] = []
        func walk(_ nodes: [OrganizerNode]) {
            for node in nodes {
                switch node {
                case .project(let p): result.append(p.id); walk(p.children)
                case .folder(let f): result.append(f.id); walk(f.children)
                case .connection: break
                }
            }
        }
        for workspace in app.connections.organizer.workspaces {
            result.append(workspace.id)
            walk(workspace.children)
        }
        return result
    }
}

/// Holds recently deleted connections so an unattended delete stays undoable. Entries
/// keep their Keychain secrets; those are only destroyed when an entry is purged.
@MainActor
@Observable
final class MCPConnectionTrash {
    struct Entry: Identifiable {
        let id: UUID
        let profile: ConnectionProfile
        let parentID: UUID?
        let deletedAt: Date
    }

    /// Deliberately small: a safety net for a mistaken call, not an archive.
    static let capacity = 10

    private(set) var entries: [Entry] = []

    func put(profile: ConnectionProfile, parentID: UUID?, connections: ConnectionsModel) {
        // Drop the tree node and the profile, but leave the Keychain entry in place.
        connections.removeProfileKeepingSecrets(profile.id)
        entries.insert(Entry(id: profile.id, profile: profile, parentID: parentID,
                             deletedAt: Date()), at: 0)
        while entries.count > Self.capacity, let oldest = entries.popLast() {
            connections.destroySecrets(for: oldest.profile)
        }
    }

    @discardableResult
    func restore(id: UUID, connections: ConnectionsModel) -> ConnectionProfile? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        // The Keychain entry survived, so re-filing the profile is enough.
        connections.reinstate(entry.profile, into: entry.parentID)
        return entry.profile
    }
}
