import XCTest
@testable import DBSecurity
@testable import DBKit

final class SecretsVaultTests: XCTestCase {

    private let account = "11111111-2222-3333-4444-555555555555"

    // MARK: Update rules (must match what the per-item store did)

    func testNilLeavesAFieldUntouched() {
        var vault = SecretsVault()
        vault.apply(Secrets(databasePassword: "pg", sshPassword: "ssh"), for: account)
        // Only the database password is named here; the SSH one must survive.
        vault.apply(Secrets(databasePassword: "pg2"), for: account)

        XCTAssertEqual(vault.secrets(for: account).databasePassword, "pg2")
        XCTAssertEqual(vault.secrets(for: account).sshPassword, "ssh")
    }

    func testEmptyStringClearsAField() {
        var vault = SecretsVault()
        vault.apply(Secrets(databasePassword: "pg", sshPassword: "ssh"), for: account)
        vault.apply(Secrets(databasePassword: ""), for: account)

        XCTAssertNil(vault.secrets(for: account).databasePassword)
        XCTAssertEqual(vault.secrets(for: account).sshPassword, "ssh")
    }

    func testClearingEverythingDropsTheEntry() {
        var vault = SecretsVault()
        vault.apply(Secrets(databasePassword: "pg"), for: account)
        vault.apply(Secrets(databasePassword: ""), for: account)
        XCTAssertFalse(vault.contains(account))
    }

    func testEntriesAreIndependent() {
        var vault = SecretsVault()
        vault.apply(Secrets(databasePassword: "a"), for: "A")
        vault.apply(Secrets(databasePassword: "b"), for: "B")
        vault.remove("A")

        XCTAssertFalse(vault.contains("A"))
        XCTAssertEqual(vault.secrets(for: "B").databasePassword, "b")
    }

    // MARK: Migration

    func testAdoptSeedsAnEntryFromTheOldStorage() {
        var vault = SecretsVault()
        vault.adopt(StoredSecrets(databasePassword: "legacy"), for: account)
        XCTAssertEqual(vault.secrets(for: account).databasePassword, "legacy")
    }

    /// Migration must never clobber a value the vault already holds — that would
    /// resurrect a password the user has since changed.
    func testAdoptNeverOverwritesWhatIsAlreadyMigrated() {
        var vault = SecretsVault()
        vault.apply(Secrets(databasePassword: "current"), for: account)
        vault.adopt(StoredSecrets(databasePassword: "stale"), for: account)
        XCTAssertEqual(vault.secrets(for: account).databasePassword, "current")
    }

    func testAdoptIgnoresAnEmptyLegacyEntry() {
        var vault = SecretsVault()
        vault.adopt(StoredSecrets(), for: account)
        XCTAssertFalse(vault.contains(account))
    }

    // MARK: Encoding

    func testRoundTripsThroughJSON() throws {
        var vault = SecretsVault()
        vault.apply(Secrets(databasePassword: "pg", sshPassword: "s", sshPassphrase: "p"),
                    for: account)
        let data = try JSONEncoder().encode(vault)
        let decoded = try JSONDecoder().decode(SecretsVault.self, from: data)
        XCTAssertEqual(decoded, vault)
        XCTAssertEqual(decoded.secrets(for: account).sshPassphrase, "p")
    }

    func testMissingSecretsReadAsEmptyNotAFailure() {
        XCTAssertEqual(SecretsVault().secrets(for: "nobody").databasePassword, nil)
    }
}
