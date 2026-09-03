import XCTest
@testable import DBKit
@testable import DBPersistence

/// The stores that a UI gesture writes through are split into `encode` (on the
/// caller's isolation) and `write` (off it). The split only helps if the two
/// halves together still behave exactly like the old single `save` — in
/// particular, `encode` has to keep throwing the refusal, because that is the
/// part the user is told about.
final class StoreEncodeWriteTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func profile(_ name: String) -> ConnectionProfile {
        ConnectionProfile(name: name, kind: .postgres, host: "127.0.0.1", port: 5432,
                          database: "shop", username: "tessera", tlsMode: .disable)
    }

    // MARK: Organizer

    func testOrganizerEncodeThenWriteRoundTrips() throws {
        let store = OrganizerStore(fileURL: directory.appendingPathComponent("organizer.json"))
        let document = OrganizerDocument(workspaces: [
            Workspace(name: "My Connections", children: [
                .folder(Folder(name: "staging", children: [.connection(ConnectionRef(profileID: UUID()))]))
            ])
        ])
        try store.write(try store.encode(document))
        XCTAssertEqual(try store.load(), document)
    }

    func testOrganizerWriteKeepsABackupOfWhatWasThere() throws {
        let store = OrganizerStore(fileURL: directory.appendingPathComponent("organizer.json"))
        let first = OrganizerDocument(workspaces: [Workspace(name: "first")])
        try store.write(try store.encode(first))
        try store.write(try store.encode(OrganizerDocument(workspaces: [Workspace(name: "second")])))

        let previous = store.backups.directory.appendingPathComponent("organizer.previous.json")
        let restored = try JSONDecoder().decode(OrganizerDocument.self, from: Data(contentsOf: previous))
        XCTAssertEqual(restored, first)
    }

    // MARK: Profiles

    func testProfileEncodeThenWriteRoundTrips() throws {
        let store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let profiles = [profile("one"), profile("two")]
        try store.write(try store.encode(profiles))
        XCTAssertEqual(try store.load().map(\.name), ["one", "two"])
    }

    /// The refusal has to surface from `encode`, before anything is handed to a
    /// writer — a caller that only learned about it later would already have told
    /// the user the connections were saved.
    func testProfileEncodeRefusesASilentRemovalAndWritesNothing() throws {
        let store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let kept = profile("one")
        try store.save([kept, profile("two")])

        XCTAssertThrowsError(try store.encode([kept])) { error in
            XCTAssertEqual(error as? ProfileStoreError, .wouldRemoveProfiles(names: ["two"]))
        }
        XCTAssertEqual(try store.load().count, 2, "the file must be untouched by a refused encode")
    }

    func testProfileEncodeAllowsARemovalThatWasAskedFor() throws {
        let store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let kept = profile("one")
        try store.save([kept, profile("two")])
        try store.write(try store.encode([kept], allowingRemovals: true))
        XCTAssertEqual(try store.load().map(\.name), ["one"])
    }
}

/// A background write is still a write: if it fails, the caller has to be able to
/// tell the user, or the app reports a save that never landed.
final class StoreWriteFailureTests: XCTestCase {
    func testProfileWriteThrowsWhenItCannotWrite() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString)/nested/profiles.json")
        let store = ProfileStore(fileURL: missing)
        let profiles = [ConnectionProfile(name: "one", kind: .postgres, host: "127.0.0.1",
                                          port: 5432, database: "shop", username: "tessera",
                                          tlsMode: .disable)]
        let data = try store.encode(profiles)
        XCTAssertThrowsError(try store.write(data))
    }

    func testOrganizerWriteThrowsWhenItCannotWrite() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString)/nested/organizer.json")
        let store = OrganizerStore(fileURL: missing)
        let data = try store.encode(OrganizerDocument(workspaces: [Workspace(name: "one")]))
        XCTAssertThrowsError(try store.write(data))
    }
}
