import Foundation
import DBKit

/// Bridges a `ConnectionProfile` to its Keychain-stored secrets.
///
/// Everything lives in **one** Keychain item (`SecretsVault`). The Keychain's access
/// prompt is per item, so a build with a new signature used to ask once per stored
/// password — three per connection. One item means one prompt.
///
/// Secrets written by earlier versions are still in per-profile items; they are
/// migrated on first read, one connection at a time, so nobody faces a wall of
/// prompts at launch.
public final class ProfileSecretsStore: @unchecked Sendable {
    private let keychain: KeychainStore
    /// The vault's own account name. Not a valid UUID, so it can never collide with
    /// a profile's `keychainAccount`.
    private let vaultAccount = "vault.v1"

    private let lock = NSLock()
    /// Read once per launch, then kept in memory: the vault is rewritten whole, so
    /// every write is read-modify-write and must not race.
    private var cached: SecretsVault?

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    // MARK: Vault I/O

    private func loadVault() throws -> SecretsVault {
        if let cached { return cached }
        guard let json = try keychain.get(account: vaultAccount),
              let data = json.data(using: .utf8),
              let vault = try? JSONDecoder().decode(SecretsVault.self, from: data) else {
            let empty = SecretsVault()
            cached = empty
            return empty
        }
        cached = vault
        return vault
    }

    private func saveVault(_ vault: SecretsVault) throws {
        let data = try JSONEncoder().encode(vault)
        try keychain.set(String(decoding: data, as: UTF8.self), account: vaultAccount)
        cached = vault
    }

    // MARK: API

    public func save(for profile: ConnectionProfile, secrets: Secrets) throws {
        try lock.withLock {
            var vault = try loadVault()
            vault.apply(secrets, for: profile.keychainAccount)
            try saveVault(vault)
            // Anything left in the old items would shadow nothing, but it would keep
            // prompting; drop it now that the vault is authoritative.
            try? deleteLegacy(profile)
        }
    }

    public func load(for profile: ConnectionProfile) throws -> Secrets {
        try lock.withLock {
            let account = profile.keychainAccount
            var vault = try loadVault()
            if vault.contains(account) { return vault.secrets(for: account) }

            // First time we've seen this profile since the move to one item.
            let legacy = try loadLegacy(profile)
            guard !legacy.isEmpty else { return Secrets() }
            vault.adopt(legacy, for: account)
            try saveVault(vault)
            // Only now — losing the originals before the vault write lands would
            // lose the password outright.
            try? deleteLegacy(profile)
            return legacy.secrets
        }
    }

    public func deleteAll(for profile: ConnectionProfile) throws {
        try lock.withLock {
            var vault = try loadVault()
            vault.remove(profile.keychainAccount)
            try saveVault(vault)
            try? deleteLegacy(profile)
        }
    }

    /// Drops every stored secret not backed by a current connection: vault entries
    /// and stray pre-vault items alike. Deletes never read the secret, so this runs
    /// at launch without an access prompt. Pass the `keychainAccount` of every
    /// profile that still exists.
    public func purgeOrphans(keeping accounts: Set<String>) {
        lock.withLock {
            // Vault entries first.
            if var vault = try? loadVault() {
                let stale = vault.entries.keys.filter { !accounts.contains($0) }
                if !stale.isEmpty {
                    for account in stale { vault.remove(account) }
                    try? saveVault(vault)
                }
            }
            // Then any leftover per-item accounts (base UUID, or its .ssh.* children).
            guard let stored = try? keychain.allAccounts() else { return }
            for account in stored where account != vaultAccount {
                let base = account.components(separatedBy: ".ssh.").first ?? account
                if !accounts.contains(base) { try? keychain.delete(account: account) }
            }
        }
    }

    // MARK: Pre-vault storage

    private func dbAccount(_ p: ConnectionProfile) -> String { p.keychainAccount }
    private func sshPasswordAccount(_ p: ConnectionProfile) -> String { "\(p.keychainAccount).ssh.password" }
    private func sshPassphraseAccount(_ p: ConnectionProfile) -> String { "\(p.keychainAccount).ssh.passphrase" }

    private func loadLegacy(_ profile: ConnectionProfile) throws -> StoredSecrets {
        StoredSecrets(
            databasePassword: try keychain.get(account: dbAccount(profile)),
            sshPassword: try keychain.get(account: sshPasswordAccount(profile)),
            sshPassphrase: try keychain.get(account: sshPassphraseAccount(profile)))
    }

    private func deleteLegacy(_ profile: ConnectionProfile) throws {
        try keychain.delete(account: dbAccount(profile))
        try keychain.delete(account: sshPasswordAccount(profile))
        try keychain.delete(account: sshPassphraseAccount(profile))
    }
}
