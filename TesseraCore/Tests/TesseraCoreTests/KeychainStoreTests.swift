import XCTest
import DBKit
@testable import DBSecurity

/// Keychain tests touch the real login Keychain, so they only run when
/// TESSERA_KEYCHAIN_TEST=1 is set (avoids prompts/hangs in plain `swift test`).
final class KeychainStoreTests: XCTestCase {

    private func storeOrSkip() throws -> KeychainStore {
        guard ProcessInfo.processInfo.environment["TESSERA_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("Set TESSERA_KEYCHAIN_TEST=1 to run Keychain tests")
        }
        // Use a throwaway service so we never touch real app secrets.
        return KeychainStore(service: "io.github.tedyno.tessera.tests")
    }

    func testSetGetDelete() throws {
        let store = try storeOrSkip()
        let account = "test-\(UUID().uuidString)"
        defer { try? store.delete(account: account) }

        XCTAssertNil(try store.get(account: account))
        try store.set("s3cr3t", account: account)
        XCTAssertEqual(try store.get(account: account), "s3cr3t")
        // Overwrite.
        try store.set("updated", account: account)
        XCTAssertEqual(try store.get(account: account), "updated")
        try store.delete(account: account)
        XCTAssertNil(try store.get(account: account))
    }

    func testProfileSecretsRoundTrip() throws {
        let store = try storeOrSkip()
        let secrets = ProfileSecretsStore(keychain: store)
        let profile = ConnectionProfile(
            name: "t", kind: .postgres, host: "h", database: "d", username: "u",
            ssh: SSHConfig(host: "b", username: "d", authMethod: .password)
        )
        defer { try? secrets.deleteAll(for: profile) }

        try secrets.save(for: profile, secrets: Secrets(databasePassword: "pw", sshPassword: "sshpw"))
        let loaded = try secrets.load(for: profile)
        XCTAssertEqual(loaded.databasePassword, "pw")
        XCTAssertEqual(loaded.sshPassword, "sshpw")
        XCTAssertNil(loaded.sshPassphrase)
    }
}
