import XCTest
@testable import DBKit
@testable import DBPersistence

/// Connection parameters exist nowhere else. The write that destroys them is not a
/// bad value but a *short list* — a failed decode, a seed that thought this was a
/// first run — and every one of those looks like an ordinary save.
final class ProfileStoreGuardTests: XCTestCase {
    private var directory: URL!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func profile(_ name: String) -> ConnectionProfile {
        ConnectionProfile(name: name, kind: .postgres, host: "127.0.0.1", port: 5432,
                          database: "shop", username: "tessera", tlsMode: .disable)
    }

    func testFirstRunWritesWithoutComplaint() throws {
        try store.save([profile("one")])
        XCTAssertEqual(try store.load().count, 1)
    }

    func testAddingAndEditingIsNotAffected() throws {
        let existing = profile("one")
        try store.save([existing])
        try store.save([existing, profile("two")])
        XCTAssertEqual(try store.load().count, 2)
    }

    /// The 2026-08-28 loss in miniature: a caller with an empty in-memory list saves
    /// a single seeded connection over 34 real ones.
    func testSaveThatWouldWipeStoredProfilesIsRefused() throws {
        let stored = (1...34).map { profile("connection \($0)") }
        try store.save(stored)

        XCTAssertThrowsError(try store.save([profile("Local (Docker)")])) { error in
            guard case ProfileStoreError.wouldRemoveProfiles(let names) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(names.count, 34)
        }
        // The point of refusing is that the file is untouched.
        XCTAssertEqual(try store.load().count, 34)
    }

    func testDeletingIsAllowedWhenAskedFor() throws {
        let keep = profile("keep")
        try store.save([keep, profile("drop")])
        try store.save([keep], allowingRemovals: true)
        XCTAssertEqual(try store.load().map(\.name), ["keep"])
    }

    /// An unreadable file is the one case where there is no way to know what a write
    /// would destroy — exactly the situation an old build hits on a newer file.
    func testSaveOverAnUnreadableFileIsRefused() throws {
        try Data("{ not json".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.save([profile("one")])) { error in
            guard case ProfileStoreError.unreadableStore = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("{ not json".utf8))
    }

    /// Recovery depends on the previous content being copied aside before a write.
    func testEarlierContentIsKeptAsideOnEveryWrite() throws {
        let first = profile("first")
        try store.save([first])
        try store.save([first, profile("second")])
        let previous = store.backups.directory.appendingPathComponent("profiles.previous.json")
        let kept = try JSONDecoder().decode([ConnectionProfile].self,
                                            from: Data(contentsOf: previous))
        XCTAssertEqual(kept.map(\.name), ["first"])
    }
}
