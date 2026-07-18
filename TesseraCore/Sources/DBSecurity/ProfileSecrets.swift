import Foundation
import DBKit

/// Bridges a `ConnectionProfile` to its Keychain-stored secrets. Account keys are
/// derived from the profile's stable `keychainAccount` so they survive edits.
public struct ProfileSecretsStore: Sendable {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    private func dbAccount(_ p: ConnectionProfile) -> String { p.keychainAccount }
    private func sshPasswordAccount(_ p: ConnectionProfile) -> String { "\(p.keychainAccount).ssh.password" }
    private func sshPassphraseAccount(_ p: ConnectionProfile) -> String { "\(p.keychainAccount).ssh.passphrase" }

    /// Persists the provided secrets; `nil` fields are left untouched, empty
    /// strings delete the stored value.
    public func save(for profile: ConnectionProfile, secrets: Secrets) throws {
        try apply(secrets.databasePassword, account: dbAccount(profile))
        try apply(secrets.sshPassword, account: sshPasswordAccount(profile))
        try apply(secrets.sshPassphrase, account: sshPassphraseAccount(profile))
    }

    /// Loads all secrets for a profile from the Keychain.
    public func load(for profile: ConnectionProfile) throws -> Secrets {
        Secrets(
            databasePassword: try keychain.get(account: dbAccount(profile)),
            sshPassword: try keychain.get(account: sshPasswordAccount(profile)),
            sshPassphrase: try keychain.get(account: sshPassphraseAccount(profile))
        )
    }

    /// Removes every secret associated with a profile.
    public func deleteAll(for profile: ConnectionProfile) throws {
        try keychain.delete(account: dbAccount(profile))
        try keychain.delete(account: sshPasswordAccount(profile))
        try keychain.delete(account: sshPassphraseAccount(profile))
    }

    private func apply(_ value: String?, account: String) throws {
        guard let value else { return }
        if value.isEmpty {
            try keychain.delete(account: account)
        } else {
            try keychain.set(value, account: account)
        }
    }
}
