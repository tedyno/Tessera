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
    /// Schema names the user has hidden in the tree, per profile.
    private(set) var hiddenSchemasByProfile: [UUID: Set<String>] = [:]

    private let profileStore: ProfileStore
    private let organizerStore: OrganizerStore
    private let secretsStore: ProfileSecretsStore
    private let visibilityURL: URL

    init() {
        let dir = FileManager.default.temporaryDirectory
        self.profileStore = ProfileStore(
            fileURL: (try? ProfileStore.defaultURL()) ?? dir.appendingPathComponent("tessera-profiles.json"))
        self.organizerStore = OrganizerStore(
            fileURL: (try? OrganizerStore.defaultURL()) ?? dir.appendingPathComponent("tessera-organizer.json"))
        self.secretsStore = ProfileSecretsStore()
        self.visibilityURL = (try? OrganizerStore.defaultURL())?
            .deletingLastPathComponent().appendingPathComponent("schema-visibility.json")
            ?? dir.appendingPathComponent("tessera-schema-visibility.json")
        loadAll()
        loadVisibility()
    }

    // MARK: Schema visibility

    func hiddenSchemas(for profileID: UUID) -> Set<String> {
        hiddenSchemasByProfile[profileID] ?? []
    }

    func toggleSchema(_ name: String, for profileID: UUID) {
        var hidden = hiddenSchemasByProfile[profileID] ?? []
        if hidden.contains(name) { hidden.remove(name) } else { hidden.insert(name) }
        hiddenSchemasByProfile[profileID] = hidden
        saveVisibility()
    }

    private func loadVisibility() {
        guard let data = try? Data(contentsOf: visibilityURL),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        for (key, names) in raw {
            if let id = UUID(uuidString: key) { hiddenSchemasByProfile[id] = Set(names) }
        }
    }

    private func saveVisibility() {
        let raw = Dictionary(uniqueKeysWithValues: hiddenSchemasByProfile.map { ($0.key.uuidString, Array($0.value)) })
        try? JSONEncoder().encode(raw).write(to: visibilityURL, options: [.atomic])
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

    /// The tree node id for a given profile (first ref), for selecting it.
    func firstNodeID(forProfile profileID: UUID) -> UUID? {
        organizer.refs(toProfile: profileID).first?.id
    }

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

        // When reordering within the same parent, the drop index was computed before
        // removal; moving a node further down needs the index decremented by one.
        var targetIndex = index
        if let index, let location = organizer.location(of: nodeID),
           location.parent == parentID, location.index < index {
            targetIndex = index - 1
        }

        guard let removed = organizer.remove(nodeID) else { return false }
        if !organizer.insert(removed, toParent: parentID, at: targetIndex) {
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

    func setFolderColor(_ color: String?, folderID: UUID) {
        organizer.setColor(color, forFolder: folderID)
        saveOrganizer()
    }

    func setProfileColor(_ color: String?, profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].color = color
        try? profileStore.save(profiles)
    }

    /// Updates an existing profile in place (parameters + secrets).
    func updateConnection(_ profile: ConnectionProfile, secrets: Secrets) {
        try? secretsStore.save(for: profile, secrets: secrets)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try? profileStore.save(profiles)
    }

    func path(forProfile profileID: UUID) -> [String] {
        organizer.path(toProfile: profileID)
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
