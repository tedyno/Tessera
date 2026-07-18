import Foundation
import DBKit
import DBPersistence
import DBSecurity

/// Owns the saved connection profiles: loads/persists them to JSON and stores
/// their secrets in the Keychain. The organizer tree (Phase 2b) will sit on top
/// of this flat profile list.
@MainActor
@Observable
final class ConnectionsModel {
    private(set) var profiles: [ConnectionProfile] = []

    private let store: ProfileStore
    private let secretsStore: ProfileSecretsStore

    init() {
        let url = (try? ProfileStore.defaultURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tessera-profiles.json")
        self.store = ProfileStore(fileURL: url)
        self.secretsStore = ProfileSecretsStore()
        reload()
        seedLocalIfEmpty()
    }

    func reload() {
        profiles = (try? store.load()) ?? []
    }

    func profile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func secrets(for profile: ConnectionProfile) -> Secrets {
        (try? secretsStore.load(for: profile)) ?? Secrets()
    }

    @discardableResult
    func add(_ profile: ConnectionProfile, secrets: Secrets) -> Bool {
        do {
            try secretsStore.save(for: profile, secrets: secrets)
            profiles.append(profile)
            try store.save(profiles)
            return true
        } catch {
            return false
        }
    }

    func delete(_ profile: ConnectionProfile) {
        try? secretsStore.deleteAll(for: profile)
        profiles.removeAll { $0.id == profile.id }
        try? store.save(profiles)
    }

    /// Dev convenience: seed a connection to the local Docker Postgres on first
    /// run so the app is usable immediately. Remove once real onboarding exists.
    private func seedLocalIfEmpty() {
        guard profiles.isEmpty else { return }
        let profile = ConnectionProfile(
            name: "Local (Docker)", kind: .postgres, host: "127.0.0.1", port: 5432,
            database: "shop", username: "tessera", tlsMode: .disable
        )
        add(profile, secrets: Secrets(databasePassword: "tessera"))
    }
}
