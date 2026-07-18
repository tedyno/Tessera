import XCTest
import DBKit
@testable import DBPersistence

final class PersistenceTests: XCTestCase {

    func testOrganizerRoundTrip() throws {
        let ref = ConnectionRef(profileID: UUID())
        let folder = Folder(name: "Production", children: [.connection(ref)])
        let project = Project(name: "E-commerce", children: [.folder(folder)])
        let workspace = Workspace(name: "Acme", children: [.project(project)])
        let doc = OrganizerDocument(workspaces: [workspace])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = OrganizerStore(fileURL: url)
        try store.save(doc)
        let loaded = try store.load()

        XCTAssertEqual(loaded, doc)
    }

    func testOrganizerLoadMissingReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = OrganizerStore(fileURL: url)
        XCTAssertEqual(try store.load().workspaces, [])
    }

    func testProfileRoundTripDefaultsAndNoSecrets() throws {
        let profile = ConnectionProfile(
            name: "production-pg",
            kind: .postgres,
            host: "db.internal.example.com",
            database: "eshop_production",
            username: "app_readonly",
            tlsMode: .verifyFull,
            ssh: SSHConfig(host: "bastion.example.com", username: "deploy",
                           authMethod: .privateKey(path: "~/.ssh/id_ed25519"))
        )
        // Port is derived from the engine.
        XCTAssertEqual(profile.port, 5432)
        // Keychain account equals the profile ID.
        XCTAssertEqual(profile.keychainAccount, profile.id.uuidString)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(fileURL: url)
        try store.save([profile])
        XCTAssertEqual(try store.load(), [profile])

        // Safety net: the serialized profile must not contain anything password-like.
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.lowercased().contains("password"))
    }
}
