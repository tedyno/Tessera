import Foundation
import DBKit

/// One profile's secrets as stored inside the vault.
public struct StoredSecrets: Codable, Sendable, Equatable {
    public var databasePassword: String?
    public var sshPassword: String?
    public var sshPassphrase: String?

    public init(databasePassword: String? = nil, sshPassword: String? = nil,
                sshPassphrase: String? = nil) {
        self.databasePassword = databasePassword
        self.sshPassword = sshPassword
        self.sshPassphrase = sshPassphrase
    }

    public init(_ secrets: Secrets) {
        self.init(databasePassword: secrets.databasePassword,
                  sshPassword: secrets.sshPassword,
                  sshPassphrase: secrets.sshPassphrase)
    }

    public var secrets: Secrets {
        Secrets(databasePassword: databasePassword, sshPassword: sshPassword,
                sshPassphrase: sshPassphrase)
    }

    public var isEmpty: Bool {
        databasePassword == nil && sshPassword == nil && sshPassphrase == nil
    }
}

/// Every profile's secrets in one value, so they occupy a **single** Keychain item.
///
/// The Keychain prompts per item, not per query: with one item per password, a build
/// signed differently asks once for each: batching the lookup would not help, but
/// collapsing the storage does. Pure, so the merge rules are unit-tested away from
/// the Keychain itself.
public struct SecretsVault: Codable, Sendable, Equatable {
    /// Keyed by `ConnectionProfile.keychainAccount`.
    public private(set) var entries: [String: StoredSecrets]

    public init(entries: [String: StoredSecrets] = [:]) {
        self.entries = entries
    }

    public func secrets(for account: String) -> Secrets {
        entries[account]?.secrets ?? Secrets()
    }

    public func contains(_ account: String) -> Bool { entries[account] != nil }

    /// Applies an update with the same rules the per-item store used: `nil` leaves a
    /// field untouched, an empty string clears it.
    public mutating func apply(_ secrets: Secrets, for account: String) {
        var stored = entries[account] ?? StoredSecrets()
        Self.assign(secrets.databasePassword, to: &stored.databasePassword)
        Self.assign(secrets.sshPassword, to: &stored.sshPassword)
        Self.assign(secrets.sshPassphrase, to: &stored.sshPassphrase)
        if stored.isEmpty { entries[account] = nil } else { entries[account] = stored }
    }

    /// Seeds an entry that came from the old per-item storage, without overwriting
    /// anything already migrated.
    public mutating func adopt(_ stored: StoredSecrets, for account: String) {
        guard !stored.isEmpty, entries[account] == nil else { return }
        entries[account] = stored
    }

    public mutating func remove(_ account: String) { entries[account] = nil }

    private static func assign(_ value: String?, to field: inout String?) {
        guard let value else { return }        // untouched
        field = value.isEmpty ? nil : value    // empty clears
    }
}
