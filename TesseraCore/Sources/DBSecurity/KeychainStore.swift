import Foundation
import Security

public enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Thin wrapper over the macOS Keychain for generic-password secrets. Stores only
/// secrets (DB passwords, SSH passphrases); everything else lives in the profile
/// JSON. Keyed by `service` (bundle ID) + `account`.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "io.github.tedyno.tessera") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Stores (or replaces) the secret for `account`.
    public func set(_ secret: String, account: String) throws {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Reads the secret for `account`, or `nil` if there is none.
    public func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the secret for `account` (no-op if absent).
    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
