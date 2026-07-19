import Foundation
import DBKit
import DBPersistence
import DBSecurity

/// Owns saved connection profiles and the organizer tree (Workspace → Project →
/// Folder → Connection). Persists profiles and the organizer to JSON and secrets
/// to the Keychain.
@MainActor
@Observable
final class ConnectionsModel {
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var organizer = OrganizerDocument()

    private let profileStore: ProfileStore
    private let organizerStore: OrganizerStore
    private let secretsStore: ProfileSecretsStore

    init() {
        let dir = FileManager.default.temporaryDirectory
        self.profileStore = ProfileStore(
            fileURL: (try? ProfileStore.defaultURL()) ?? dir.appendingPathComponent("tessera-profiles.json"))
        self.organizerStore = OrganizerStore(
            fileURL: (try? OrganizerStore.defaultURL()) ?? dir.appendingPathComponent("tessera-organizer.json"))
        self.secretsStore = ProfileSecretsStore()
        loadAll()
    }

    // MARK: Loading / seeding

    private func loadAll() {
        profiles = (try? profileStore.load()) ?? []
        organizer = (try? organizerStore.load()) ?? OrganizerDocument()
        if profiles.isEmpty { seedLocalProfile() }
        if organizer.workspaces.isEmpty {
            let refs = profiles.map { OrganizerNode.connection(ConnectionRef(profileID: $0.id)) }
            organizer.workspaces = [Workspace(name: "My Connections", children: refs)]
            saveOrganizer()
        }
    }

    /// Dev convenience: a connection to the local Docker Postgres on first run.
    private func seedLocalProfile() {
        let profile = ConnectionProfile(
            name: "Local (Docker)", kind: .postgres, host: "127.0.0.1", port: 5432,
            database: "shop", username: "tessera", tlsMode: .disable)
        try? secretsStore.save(for: profile, secrets: Secrets(databasePassword: "tessera"))
        profiles = [profile]
        try? profileStore.save(profiles)
    }

    // MARK: Lookups

    func profile(id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

    func profileID(forNode nodeID: UUID) -> UUID? { organizer.profileID(forNode: nodeID) }

    func secrets(for profile: ConnectionProfile) -> Secrets {
        (try? secretsStore.load(for: profile)) ?? Secrets()
    }

    private var defaultParentID: UUID? { organizer.workspaces.first?.id }

    /// The node id of the first connection in the tree (for initial selection).
    var firstConnectionNodeID: UUID? {
        func scan(_ nodes: [OrganizerNode]) -> UUID? {
            for node in nodes {
                if case .connection = node { return node.id }
                if let children = node.children, let found = scan(children) { return found }
            }
            return nil
        }
        for workspace in organizer.workspaces {
            if let found = scan(workspace.children) { return found }
        }
        return nil
    }

    // MARK: Mutations

    /// Adds a connection and returns the new tree node's id.
    @discardableResult
    func addConnection(_ profile: ConnectionProfile, secrets: Secrets, into parentID: UUID? = nil) -> UUID {
        try? secretsStore.save(for: profile, secrets: secrets)
        profiles.append(profile)
        try? profileStore.save(profiles)
        let ref = ConnectionRef(profileID: profile.id)
        organizer.append(.connection(.init(id: ref.id, profileID: profile.id)),
                         toParent: parentID ?? defaultParentID ?? UUID())
        saveOrganizer()
        return ref.id
    }

    func addFolder(name: String, into parentID: UUID?) {
        guard let parentID = parentID ?? defaultParentID else { return }
        organizer.append(.folder(Folder(name: name)), toParent: parentID)
        saveOrganizer()
    }

    func addProject(name: String, into workspaceID: UUID?) {
        guard let workspaceID = workspaceID ?? defaultParentID else { return }
        organizer.append(.project(Project(name: name)), toParent: workspaceID)
        saveOrganizer()
    }

    func addWorkspace(name: String) {
        organizer.workspaces.append(Workspace(name: name))
        saveOrganizer()
    }

    func rename(_ id: UUID, to name: String) {
        guard !name.isEmpty else { return }
        organizer.rename(id, to: name)
        saveOrganizer()
    }

    /// Deletes a node. If it is a connection whose profile no longer has any refs,
    /// the profile and its secrets are removed too.
    func deleteNode(_ id: UUID) {
        let profileID = organizer.profileID(forNode: id)
        organizer.remove(id)
        if let profileID, organizer.refs(toProfile: profileID).isEmpty {
            if let profile = profile(id: profileID) {
                try? secretsStore.deleteAll(for: profile)
            }
            profiles.removeAll { $0.id == profileID }
            try? profileStore.save(profiles)
        }
        saveOrganizer()
    }

    /// Moves a node under a new parent container, optionally at a specific index.
    /// Rejects no-op moves and moving a container into its own subtree.
    @discardableResult
    func move(nodeID: UUID, toParent parentID: UUID, at index: Int? = nil) -> Bool {
        guard nodeID != parentID else { return false }
        guard !organizer.descendants(of: nodeID).contains(parentID) else { return false }
        guard let removed = organizer.remove(nodeID) else { return false }
        if !organizer.insert(removed, toParent: parentID, at: index) {
            organizer.append(removed, toParent: defaultParentID ?? UUID())
            saveOrganizer()
            return false
        }
        saveOrganizer()
        return true
    }

    func deleteWorkspace(_ id: UUID) {
        organizer.workspaces.removeAll { $0.id == id }
        saveOrganizer()
    }

    /// Deletes by id whether it is a workspace or a tree node.
    func delete(id: UUID) {
        if organizer.workspaces.contains(where: { $0.id == id }) {
            deleteWorkspace(id)
        } else {
            deleteNode(id)
        }
    }

    func name(forNode id: UUID) -> String? {
        if let workspace = organizer.workspaces.first(where: { $0.id == id }) { return workspace.name }
        return organizer.node(id: id)?.displayName
    }

    private func saveOrganizer() {
        try? organizerStore.save(organizer)
    }
}
