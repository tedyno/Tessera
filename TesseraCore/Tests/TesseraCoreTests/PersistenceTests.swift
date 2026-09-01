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

    // MARK: Damaged profile store

    /// A missing file is a first run: empty, no error. The app may seed over it.
    func testProfileStoreReportsAMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = ProfileStore(fileURL: url)
        XCTAssertFalse(store.fileExists)
        XCTAssertTrue(try store.load().isEmpty)
    }

    /// A file that exists but won't parse must **throw**, never read as "no
    /// connections" — that is what let a damaged file be replaced by a seeded
    /// sample profile, destroying the only copy of the user's connections.
    func testProfileStoreThrowsOnADamagedFileInsteadOfReadingEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ this is not profiles json".utf8).write(to: url)

        let store = ProfileStore(fileURL: url)
        XCTAssertTrue(store.fileExists)
        XCTAssertThrowsError(try store.load())
        // The caller decides what to do; loading must not have touched the file.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "{ this is not profiles json")
    }

    /// An empty file still exists, so it is not a first run either.
    func testProfileStoreTreatsAnEmptyFileAsDamaged() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)

        let store = ProfileStore(fileURL: url)
        XCTAssertTrue(store.fileExists)
        XCTAssertThrowsError(try store.load())
    }

    /// Every store must live under the running build's own identifier, so a
    /// development build cannot read or overwrite the released app's data.
    func testStoresAreScopedToTheRunningBuild() throws {
        let dev = "io.github.tedyno.tessera.dev"
        let release = StorageIdentity.releaseBundleID
        let profiles = try ProfileStore.defaultURL(bundleID: dev)
        let organizer = try OrganizerStore.defaultURL(bundleID: dev)
        XCTAssertEqual(profiles.deletingLastPathComponent().lastPathComponent, dev)
        XCTAssertEqual(organizer.deletingLastPathComponent().lastPathComponent, dev)
        XCTAssertNotEqual(profiles, try ProfileStore.defaultURL(bundleID: release))
    }

    // MARK: Backups

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func day(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    /// Saving a shorter list must leave the previous content recoverable — this is
    /// exactly the case where a profile list gets replaced by a seeded sample.
    func testSavingProfilesKeepsThePreviousVersion() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(fileURL: dir.appendingPathComponent("profiles.json"))

        let real = (1...3).map {
            ConnectionProfile(name: "db\($0)", kind: .postgres, host: "h\($0)", port: 5432,
                              database: "d\($0)", username: "u")
        }
        try store.save(real)
        // Deliberately shrinking the list: the implicit form of this write is now
        // refused outright (see ProfileStoreGuardTests), but a real deletion still
        // has to leave the earlier content recoverable.
        try store.save([ConnectionProfile(name: "Local (Docker)", kind: .postgres,
                                          host: "127.0.0.1", port: 5432,
                                          database: "shop", username: "tessera")],
                       allowingRemovals: true)

        XCTAssertEqual(try store.load().count, 1)
        let previous = store.backups.directory.appendingPathComponent("profiles.previous.json")
        let recovered = try JSONDecoder().decode([ConnectionProfile].self,
                                                 from: Data(contentsOf: previous))
        XCTAssertEqual(recovered.map(\.name), ["db1", "db2", "db3"])
    }

    func testFirstWriteOfADayIsKept() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("profiles.json")
        let backups = StoreBackups(directory: dir.appendingPathComponent("backups"))

        try Data("morning".utf8).write(to: file)
        backups.capture(file, now: day("2026-08-11 09:00"))
        try Data("noon".utf8).write(to: file)
        backups.capture(file, now: day("2026-08-11 12:00"))

        // The day's snapshot holds the state before anything that day changed it.
        let daily = backups.directory.appendingPathComponent("profiles-2026-08-11.json")
        XCTAssertEqual(try String(contentsOf: daily, encoding: .utf8), "morning")
        // …while `.previous` tracks the most recent write.
        let previous = backups.directory.appendingPathComponent("profiles.previous.json")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "noon")
    }

    func testDailySnapshotsArePrunedToTheRetentionWindow() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("profiles.json")
        let backups = StoreBackups(directory: dir.appendingPathComponent("backups"), keepDays: 3)

        for dayOfMonth in 1...6 {
            try Data("day\(dayOfMonth)".utf8).write(to: file)
            backups.capture(file, now: day(String(format: "2026-08-%02d 10:00", dayOfMonth)))
        }
        let kept = backups.snapshots(of: "profiles").map(\.lastPathComponent)
        XCTAssertEqual(kept, ["profiles-2026-08-06.json", "profiles-2026-08-05.json",
                              "profiles-2026-08-04.json"])
    }

    /// A damaged file is backed up exactly as found — re-encoding it from memory
    /// would lose whatever is still salvageable in it.
    func testDamagedContentIsBackedUpVerbatim() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("profiles.json")
        let backups = StoreBackups(directory: dir.appendingPathComponent("backups"))
        try Data("{ truncated".utf8).write(to: file)

        backups.capture(file, now: day("2026-08-11 10:00"))
        let previous = backups.directory.appendingPathComponent("profiles.previous.json")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "{ truncated")
    }

    func testNothingIsCapturedWithoutAFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = StoreBackups(directory: dir.appendingPathComponent("backups"))
        backups.capture(dir.appendingPathComponent("absent.json"), now: day("2026-08-11 10:00"))
        XCTAssertTrue(backups.snapshots(of: "absent").isEmpty)
    }
}
