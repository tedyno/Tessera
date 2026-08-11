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
    /// Set when the profiles file exists but could not be read. While it is set,
    /// nothing is written to that file — an empty in-memory list must never be
    /// saved over connections that are merely unreadable.
    private(set) var profileStoreFailure: String?
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

    /// Drops any Keychain secret left behind by a connection that no longer exists
    /// (e.g. deleted by an older build). Reading the vault item prompts on a
    /// freshly-signed build, so this runs off the main thread and is deliberately
    /// *not* called during launch — doing it mid-launch pops the system dialog
    /// before the app is frontmost, and focus never returns to it. `AppModel` calls
    /// this once the app has become active.
    func purgeOrphanSecrets() {
        let store = secretsStore
        let accounts = Set(profiles.map(\.keychainAccount))
        Task.detached(priority: .utility) { store.purgeOrphans(keeping: accounts) }
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
        let profilesExisted = profileStore.fileExists
        do {
            profiles = try profileStore.load()
        } catch {
            // The file is there but unreadable. Treating that as "no connections
            // yet" would seed a sample profile and overwrite the only copy of the
            // user's connections, so instead: keep nothing, write nothing, and say
            // so. Every later save is blocked until the file is dealt with.
            profiles = []
            profileStoreFailure = Self.message(for: error, url: profileStore.fileURL,
                                               backups: profileStore.backups.directory)
        }
        organizer = (try? organizerStore.load()) ?? OrganizerDocument()
        // Only a genuinely absent file is a first run.
        if profiles.isEmpty, !profilesExisted, profileStoreFailure == nil {
            seedLocalProfile()
        }
        if organizer.workspaces.isEmpty, profileStoreFailure == nil {
            let refs = profiles.map { OrganizerNode.connection(ConnectionRef(profileID: $0.id)) }
            organizer.workspaces = [Workspace(name: "My Connections", children: refs)]
            saveOrganizer()
        }
    }

    private static func message(for error: Error, url: URL, backups: URL) -> String {
        String(localized: """
            Tessera could not read your saved connections from \(url.path).

            Nothing has been changed or overwritten, and saving is disabled until \
            this is resolved. Earlier versions are in \(backups.path) — replace the \
            file with one of those and start Tessera again.

            (\(String(describing: error)))
            """)
    }

    /// Writes the profile list, unless the stored file failed to load — in that
    /// case the in-memory list is empty and saving would erase the real one.
    private func saveProfiles() {
        guard profileStoreFailure == nil else { return }
        try? profileStore.save(profiles)
    }

    /// Dev convenience: a connection to the local Docker Postgres on first run.
    private func seedLocalProfile() {
        let profile = ConnectionProfile(
            name: "Local (Docker)", kind: .postgres, host: "127.0.0.1", port: 5432,
            database: "shop", username: "tessera", tlsMode: .disable)
        try? secretsStore.save(for: profile, secrets: Secrets(databasePassword: "tessera"))
        profiles = [profile]
        saveProfiles()
    }

    // MARK: Lookups

    func profile(id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

    func profileID(forNode nodeID: UUID) -> UUID? { organizer.profileID(forNode: nodeID) }

    func secrets(for profile: ConnectionProfile) -> Secrets {
        (try? secretsStore.load(for: profile)) ?? Secrets()
    }

    /// Loads secrets, propagating a Keychain *denial* (so the UI can prompt a retry)
    /// while treating a missing/other error as simply no stored secret.
    func loadSecrets(for profile: ConnectionProfile) throws -> Secrets {
        do {
            return try secretsStore.load(for: profile)
        } catch let error as KeychainError {
            if case .accessDenied = error { throw error }
            return Secrets()
        }
    }

    private var defaultParentID: UUID? { organizer.workspaces.first?.id }

    /// The tree node id for a given profile (first ref), for selecting it.
    func firstNodeID(forProfile profileID: UUID) -> UUID? {
        organizer.refs(toProfile: profileID).first?.id
    }

    /// Changes whenever the organizer or any profile changes; lets the outline
    /// view refresh when a connection is renamed/recolored (profiles aren't part
    /// of the organizer's own hash).
    var stateVersion: Int {
        var hasher = Hasher()
        hasher.combine(organizer)
        hasher.combine(profiles)
        return hasher.finalize()
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
        saveProfiles()
        let ref = ConnectionRef(profileID: profile.id)
        let node = OrganizerNode.connection(.init(id: ref.id, profileID: profile.id))
        // No parent means no workspace: the connection sits loose above them all.
        // The same fallback catches a parent that vanished while a sheet was open
        // (e.g. deleted over MCP) — better loose than an invisible orphaned profile.
        if !organizer.append(node, toParent: parentID ?? OrganizerDocument.looseParentID) {
            organizer.append(node, toParent: OrganizerDocument.looseParentID)
        }
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
        // Collect before removing: a container takes its whole subtree with it, and
        // every connection in there would otherwise leave a profile and Keychain
        // entry behind with nothing in the UI pointing at them.
        let orphaned = organizer.profileIDs(inSubtreeOf: id)
        organizer.remove(id)
        discardProfiles(orphaned)
        saveOrganizer()
    }

    /// Deletes a profile and its secrets once nothing in the tree refers to it.
    private func discardProfiles(_ profileIDs: [UUID]) {
        var removed: [UUID] = []
        for profileID in Set(profileIDs) where organizer.refs(toProfile: profileID).isEmpty {
            if let profile = profile(id: profileID) {
                try? secretsStore.deleteAll(for: profile)
            }
            profiles.removeAll { $0.id == profileID }
            removed.append(profileID)
        }
        guard !removed.isEmpty else { return }
        saveProfiles()
        // A live session (and any tab on it) would otherwise outlive the connection.
        onProfilesRemoved(removed)
    }

    /// Called with profiles that no longer exist anywhere in the tree, so the app can
    /// close their sessions and tabs. Injected because this store knows nothing about
    /// the query console.
    var onProfilesRemoved: ([UUID]) -> Void = { _ in }
    /// Fired after a profile mutates in place (rename, recolor, edited
    /// parameters) so live state derived from it — session name/color shown in
    /// tabs and the status bar — can follow without a reconnect.
    var onProfileChanged: (ConnectionProfile) -> Void = { _ in }

    /// Deletes a container, either taking its contents with it or keeping them by
    /// moving them up a level (into another workspace, for a workspace).
    func deleteContainer(_ id: UUID, removingContents: Bool) {
        let isWorkspace = organizer.workspaces.contains { $0.id == id }
        // Keeping the contents of the last workspace is impossible — there is nowhere
        // to move them. Fall through to the deleting path so the profiles and their
        // Keychain entries are still cleaned up instead of silently orphaned.
        let target = isWorkspace ? fallbackWorkspaceID(excluding: id) : nil
        let canKeep = !isWorkspace || target != nil
        guard removingContents || !canKeep else {
            if isWorkspace {
                organizer.removeWorkspace(id, movingChildrenInto: target)
            } else {
                organizer.removeKeepingChildren(id)
            }
            saveOrganizer()
            return
        }
        let orphaned = organizer.profileIDs(inSubtreeOf: id)
        if isWorkspace {
            organizer.removeWorkspace(id, movingChildrenInto: nil)
        } else {
            organizer.remove(id)
        }
        discardProfiles(orphaned)
        saveOrganizer()
    }

    /// Where a deleted workspace's contents go: the first workspace that isn't the one
    /// being deleted. Nil when it is the last one, so its contents can't be kept.
    func fallbackWorkspaceID(excluding id: UUID) -> UUID? {
        organizer.workspaces.first { $0.id != id }?.id
    }

    func fallbackWorkspaceName(excluding id: UUID) -> String? {
        organizer.workspaces.first { $0.id != id }?.name
    }

    /// What deleting `id` would affect, for the confirmation prompt.
    func deletionSummary(_ id: UUID) -> (connections: Int, isEmpty: Bool) {
        let connections = organizer.profileIDs(inSubtreeOf: id).count
        let children = organizer.workspaces.first { $0.id == id }?.children
            ?? organizer.node(id: id)?.children ?? []
        return (connections, children.isEmpty)
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

    /// Moves several nodes under a new parent as one contiguous block (a
    /// multi-selection drag) — see `OrganizerDocument.moveBatch` for why this isn't
    /// just `move` called once per id.
    @discardableResult
    func moveBatch(nodeIDs: [UUID], toParent parentID: UUID, at index: Int? = nil) -> Bool {
        let ok = organizer.moveBatch(nodeIDs: nodeIDs, toParent: parentID, at: index,
                                     fallback: defaultParentID ?? UUID())
        saveOrganizer()
        return ok
    }

    func deleteWorkspace(_ id: UUID) {
        deleteContainer(id, removingContents: true)
    }

    func setFolderColor(_ color: String?, folderID: UUID) {
        organizer.setColor(color, forFolder: folderID)
        saveOrganizer()
    }

    func setProfileColor(_ color: String?, profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].color = color
        saveProfiles()
        onProfileChanged(profiles[index])
    }

    /// Updates an existing profile in place (parameters + secrets).
    func updateConnection(_ profile: ConnectionProfile, secrets: Secrets) {
        try? secretsStore.save(for: profile, secrets: secrets)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
        onProfileChanged(profile)
    }

    func path(forProfile profileID: UUID) -> [String] {
        organizer.path(toProfile: profileID)
    }

    // MARK: Reversible delete (MCP trash)

    /// Removes a profile and its tree nodes but **keeps** its Keychain entry, so the
    /// deletion can be undone with the password intact. Pair with `destroySecrets`
    /// once the deletion becomes permanent.
    func removeProfileKeepingSecrets(_ profileID: UUID) {
        for ref in organizer.refs(toProfile: profileID) { organizer.remove(ref.id) }
        profiles.removeAll { $0.id == profileID }
        saveProfiles()
        saveOrganizer()
    }

    /// Erases the Keychain entries of a profile that is already gone from the tree.
    func destroySecrets(for profile: ConnectionProfile) {
        try? secretsStore.deleteAll(for: profile)
    }

    /// Puts a removed profile back where it was, reusing the Keychain entry that was
    /// deliberately left behind.
    func reinstate(_ profile: ConnectionProfile, into parentID: UUID?) {
        guard !profiles.contains(where: { $0.id == profile.id }) else { return }
        profiles.append(profile)
        saveProfiles()
        let node = OrganizerNode.connection(ConnectionRef(profileID: profile.id))
        if let parentID, organizer.append(node, toParent: parentID) {
            saveOrganizer()
        } else if let fallback = defaultParentID, organizer.append(node, toParent: fallback) {
            saveOrganizer()
        }
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
