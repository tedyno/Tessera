import XCTest
@testable import DBPersistence
@testable import DBKit

final class ConnectionBundleTests: XCTestCase {

    /// Cheap enough for tests; the real default only costs time.
    private let iterations = 1_000

    private func makeBundle() -> ConnectionBundle {
        let prod = ConnectionProfile(name: "Prod", kind: .postgres, host: "db.example.com",
                                     database: "shop", username: "app",
                                     ssh: SSHConfig(host: "bastion", username: "me",
                                                    authMethod: .password))
        let local = ConnectionProfile(name: "Local", kind: .mysql, host: "127.0.0.1",
                                      database: "dev", username: "root")
        let folder = Folder(name: "Servers", children: [.connection(ConnectionRef(profileID: prod.id))],
                            color: "red")
        let doc = OrganizerDocument(
            workspaces: [Workspace(name: "Work", children: [.folder(folder)])],
            looseConnections: [.connection(ConnectionRef(profileID: local.id))])
        return ConnectionBundle(
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            organizer: doc, profiles: [prod, local],
            secrets: [prod.id: Secrets(databasePassword: "pg-secret", sshPassword: "ssh-secret"),
                      local.id: Secrets()])
    }

    // MARK: File format

    func testRoundTripsWithThePassword() throws {
        let bundle = makeBundle()
        let password = ExportPassword.generate()
        let data = try ConnectionBundleFile.seal(bundle, password: password, iterations: iterations)
        let opened = try ConnectionBundleFile.open(data, password: password)
        XCTAssertEqual(opened, bundle)
        XCTAssertEqual(opened.secrets(for: bundle.profiles[0].id).databasePassword, "pg-secret")
        XCTAssertEqual(opened.secrets(for: bundle.profiles[0].id).sshPassword, "ssh-secret")
    }

    func testEmptySecretsAreLeftOut() {
        let bundle = makeBundle()
        XCTAssertNil(bundle.secrets[bundle.profiles[1].id.uuidString])
    }

    func testNothingReadableIsLeftInTheFile() throws {
        let data = try ConnectionBundleFile.seal(makeBundle(), password: ExportPassword.generate(),
                                                 iterations: iterations)
        let text = String(decoding: data, as: UTF8.self)
        for needle in ["pg-secret", "ssh-secret", "db.example.com", "Prod", "Servers"] {
            XCTAssertFalse(text.contains(needle), "\(needle) leaked into the file")
        }
    }

    func testWrongPasswordIsRejected() throws {
        let data = try ConnectionBundleFile.seal(makeBundle(), password: ExportPassword.generate(),
                                                 iterations: iterations)
        XCTAssertThrowsError(try ConnectionBundleFile.open(data, password: ExportPassword.generate())) {
            XCTAssertEqual($0 as? ConnectionBundleError, .wrongPassword)
        }
    }

    func testPastedPasswordIsForgiving() throws {
        let password = ExportPassword.generate()
        let data = try ConnectionBundleFile.seal(makeBundle(), password: password, iterations: iterations)
        XCTAssertNoThrow(try ConnectionBundleFile.open(data, password: "  \(password.uppercased())\n"))
    }

    func testTamperingIsDetected() throws {
        let password = ExportPassword.generate()
        let data = try ConnectionBundleFile.seal(makeBundle(), password: password, iterations: iterations)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: json["sealed"] as! String))
        sealed[sealed.count / 2] ^= 0xFF
        json["sealed"] = sealed.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try ConnectionBundleFile.open(tampered, password: password)) {
            XCTAssertEqual($0 as? ConnectionBundleError, .wrongPassword)
        }
    }

    func testForeignFilesAreNotBundles() {
        for data in [Data("hello".utf8), Data("{\"format\":\"other\"}".utf8)] {
            XCTAssertThrowsError(try ConnectionBundleFile.open(data, password: "x")) {
                XCTAssertEqual($0 as? ConnectionBundleError, .notABundle)
            }
        }
    }

    func testNewerVersionIsRefused() throws {
        let data = try ConnectionBundleFile.seal(makeBundle(), password: "p", iterations: iterations)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 99
        XCTAssertThrowsError(try ConnectionBundleFile.open(JSONSerialization.data(withJSONObject: json),
                                                           password: "p")) {
            XCTAssertEqual($0 as? ConnectionBundleError, .unsupportedVersion(99))
        }
    }

    func testAbsurdIterationCountIsRefused() throws {
        let data = try ConnectionBundleFile.seal(makeBundle(), password: "p", iterations: iterations)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for count in [0, 5_000_000_000, 4_000_000_000] {
            json["iterations"] = count
            XCTAssertThrowsError(try ConnectionBundleFile.open(JSONSerialization.data(withJSONObject: json),
                                                               password: "p")) {
                XCTAssertEqual($0 as? ConnectionBundleError, .notABundle)
            }
        }
    }

    func testSaltMakesEachExportDifferent() throws {
        let a = try ConnectionBundleFile.seal(makeBundle(), password: "p", iterations: iterations)
        let b = try ConnectionBundleFile.seal(makeBundle(), password: "p", iterations: iterations)
        XCTAssertNotEqual(a, b)
    }

    // MARK: Password

    func testGeneratedPasswordShape() {
        let password = ExportPassword.generate()
        let groups = password.split(separator: "-")
        XCTAssertEqual(groups.count, 6)
        XCTAssertTrue(groups.allSatisfy { $0.count == 5 })
        XCTAssertTrue(password.replacingOccurrences(of: "-", with: "")
            .allSatisfy { ExportPassword.alphabet.contains($0) })
        XCTAssertEqual(ExportPassword.normalized(password), password)
    }

    func testGeneratedPasswordsDiffer() {
        let passwords = Set((0..<200).map { _ in ExportPassword.generate() })
        XCTAssertEqual(passwords.count, 200)
    }
}

final class ConnectionImportPlanTests: XCTestCase {

    private func profile(_ name: String, host: String = "h") -> ConnectionProfile {
        ConnectionProfile(name: name, kind: .postgres, host: host, database: "d", username: "u")
    }

    private func bundle(_ doc: OrganizerDocument, _ profiles: [ConnectionProfile],
                        secrets: [UUID: Secrets] = [:]) -> ConnectionBundle {
        ConnectionBundle(organizer: doc, profiles: profiles, secrets: secrets)
    }

    private func allIDs(_ doc: OrganizerDocument) -> [UUID] {
        func walk(_ nodes: [OrganizerNode]) -> [UUID] {
            nodes.flatMap { [$0.id] + walk($0.children ?? []) }
        }
        return doc.workspaces.map(\.id) + walk(doc.looseConnections)
            + doc.workspaces.flatMap { walk($0.children) }
    }

    func testIntoAnEmptyTessera() {
        let a = profile("A"), b = profile("B")
        let source = OrganizerDocument(workspaces: [
            Workspace(name: "Work", children: [.folder(Folder(name: "F", children: [
                .connection(ConnectionRef(profileID: a.id))]))]),
        ], looseConnections: [.connection(ConnectionRef(profileID: b.id))])

        let plan = ConnectionImportPlan(
            bundle: bundle(source, [a, b], secrets: [a.id: Secrets(databasePassword: "pw")]),
            into: OrganizerDocument(), existingProfiles: [])

        XCTAssertEqual(plan.added.map(\.profile.id), [a.id, b.id])
        XCTAssertEqual(plan.added[0].secrets.databasePassword, "pw")
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.organizer.workspaces.map(\.name), ["Work"])
        XCTAssertEqual(plan.organizer.path(toProfile: a.id), ["Work", "F"])
        XCTAssertEqual(plan.organizer.refs(toProfile: b.id).count, 1)
        XCTAssertEqual(plan.organizer.location(of: plan.organizer.refs(toProfile: b.id)[0].id)?.parent,
                       OrganizerDocument.looseParentID)
    }

    func testExistingConfigurationIsNeverChanged() {
        let mine = profile("Mine")
        let myFolder = Folder(name: "F", children: [.connection(ConnectionRef(profileID: mine.id))],
                              color: "blue")
        let existing = OrganizerDocument(workspaces: [Workspace(name: "Work", children: [.folder(myFolder)])])

        // Same workspace and folder names, a different folder color, a new connection.
        let theirs = profile("Theirs")
        let source = OrganizerDocument(workspaces: [
            Workspace(name: "Work", children: [.folder(Folder(name: "F", children: [
                .connection(ConnectionRef(profileID: theirs.id))], color: "red"))]),
        ])
        let plan = ConnectionImportPlan(bundle: bundle(source, [theirs]), into: existing,
                                        existingProfiles: [mine])

        XCTAssertEqual(plan.organizer.workspaces.count, 1)
        XCTAssertEqual(plan.organizer.workspaces[0].id, existing.workspaces[0].id)
        guard case .folder(let merged)? = plan.organizer.workspaces[0].children.first else {
            return XCTFail("folder expected")
        }
        XCTAssertEqual(plan.organizer.workspaces[0].children.count, 1, "folder merged, not duplicated")
        XCTAssertEqual(merged.id, myFolder.id)
        XCTAssertEqual(merged.color, "blue", "existing folder keeps its color")
        XCTAssertEqual(merged.children.first, myFolder.children.first, "existing node stays first")
        XCTAssertEqual(plan.organizer.path(toProfile: theirs.id), ["Work", "F"])
    }

    func testSameProfileIsSkippedNotOverwritten() {
        var mine = profile("Prod")
        let existing = OrganizerDocument(looseConnections: [.connection(ConnectionRef(profileID: mine.id))])
        var bundled = mine
        bundled.host = "changed-elsewhere"
        mine.color = "green"
        let plan = ConnectionImportPlan(
            bundle: bundle(OrganizerDocument(looseConnections: [.connection(ConnectionRef(profileID: bundled.id))]),
                           [bundled], secrets: [bundled.id: Secrets(databasePassword: "new")]),
            into: existing, existingProfiles: [mine])

        XCTAssertTrue(plan.added.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.id), [mine.id])
        XCTAssertEqual(plan.organizer, existing)
    }

    func testLookalikeWithDifferentIDIsSkipped() {
        // A fresh install's sample connection vs. the same one exported elsewhere.
        let sample = profile("Local (Docker)", host: "127.0.0.1")
        let other = profile("Local (Docker)", host: "127.0.0.1")
        let plan = ConnectionImportPlan(
            bundle: bundle(OrganizerDocument(looseConnections: [.connection(ConnectionRef(profileID: other.id))]),
                           [other]),
            into: OrganizerDocument(), existingProfiles: [sample])
        XCTAssertEqual(plan.skipped.map(\.id), [other.id])
    }

    func testFolderOfOnlySkippedConnectionsIsNotAdded() {
        let mine = profile("Mine")
        let source = OrganizerDocument(workspaces: [
            Workspace(name: "Elsewhere", children: [
                .folder(Folder(name: "Old", children: [.connection(ConnectionRef(profileID: mine.id))])),
                .folder(Folder(name: "Empty")),
            ]),
        ])
        let plan = ConnectionImportPlan(bundle: bundle(source, [mine]), into: OrganizerDocument(),
                                        existingProfiles: [mine])
        XCTAssertEqual(plan.organizer.workspaces.map(\.name), ["Elsewhere"])
        XCTAssertEqual(plan.organizer.workspaces[0].children.compactMap(\.displayName), ["Empty"])
    }

    func testImportingTwiceAddsNothingTheSecondTime() {
        let a = profile("A")
        let source = OrganizerDocument(workspaces: [
            Workspace(name: "W", children: [.folder(Folder(name: "F", children: [
                .connection(ConnectionRef(profileID: a.id))]))]),
        ])
        let first = ConnectionImportPlan(bundle: bundle(source, [a]), into: OrganizerDocument(),
                                         existingProfiles: [])
        let second = ConnectionImportPlan(bundle: bundle(source, [a]), into: first.organizer,
                                          existingProfiles: first.added.map(\.profile))
        XCTAssertTrue(second.added.isEmpty)
        XCTAssertEqual(second.organizer, first.organizer)
    }

    func testIDsNeverCollide() {
        // A bundle whose node ids already exist here (e.g. exported from a copy of
        // this organizer) under different containers.
        let mine = profile("Mine"), theirs = profile("Theirs")
        let sharedFolderID = UUID()
        let existing = OrganizerDocument(workspaces: [
            Workspace(name: "Here", children: [.connection(ConnectionRef(id: sharedFolderID, profileID: mine.id))]),
        ])
        let source = OrganizerDocument(workspaces: [
            Workspace(id: existing.workspaces[0].id, name: "Renamed", children: [
                .folder(Folder(id: UUID(), name: "New", children: [
                    .connection(ConnectionRef(id: sharedFolderID, profileID: theirs.id))])),
            ]),
        ])
        let plan = ConnectionImportPlan(bundle: bundle(source, [theirs]), into: existing,
                                        existingProfiles: [mine])
        let ids = allIDs(plan.organizer)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(plan.organizer.workspaces.map(\.name), ["Here"], "matched by id, name untouched")
        XCTAssertEqual(plan.organizer.path(toProfile: theirs.id), ["Here", "New"])
    }

    func testProfileMissingFromTheTreeStillLands() {
        let orphan = profile("Orphan")
        let plan = ConnectionImportPlan(bundle: bundle(OrganizerDocument(), [orphan]),
                                        into: OrganizerDocument(), existingProfiles: [])
        XCTAssertEqual(plan.organizer.refs(toProfile: orphan.id).count, 1)
    }

    func testProfileReferencedTwiceGetsOneNode() {
        let a = profile("A")
        let source = OrganizerDocument(workspaces: [Workspace(name: "W", children: [
            .connection(ConnectionRef(profileID: a.id)),
            .folder(Folder(name: "F", children: [.connection(ConnectionRef(profileID: a.id))])),
        ])])
        let plan = ConnectionImportPlan(bundle: bundle(source, [a]), into: OrganizerDocument(),
                                        existingProfiles: [])
        XCTAssertEqual(plan.organizer.refs(toProfile: a.id).count, 1)
    }
}
