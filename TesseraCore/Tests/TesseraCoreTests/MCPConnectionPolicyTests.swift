import XCTest
@testable import DBKit

final class MCPConnectionPolicyTests: XCTestCase {

    private func profile(host: String = "db.example.com", port: Int = 5432,
                         database: String = "shop", user: String = "app",
                         mcpRead: Bool = true, mcpWrite: Bool = true,
                         noApproval: Bool = true) -> ConnectionProfile {
        ConnectionProfile(name: "Shop", kind: .postgres, host: host, port: port,
                          database: database, username: user,
                          mcpRead: mcpRead, mcpWrite: mcpWrite,
                          mcpWriteWithoutApproval: noApproval)
    }

    // MARK: A client may never grant itself access

    func testCreatedConnectionHasNoMCPAccess() throws {
        let created = try MCPConnectionPolicy.makeProfile(
            MCPConnectionSpec(name: "New", engine: "postgres", host: "h",
                              database: "d", user: "u", password: "secret"))
        XCTAssertFalse(created.allowsMCPRead)
        XCTAssertFalse(created.allowsMCPWrite)
        XCTAssertFalse(created.allowsMCPWriteWithoutApproval)
    }

    func testEditKeepsAccessFlagsExactlyAsTheUserLeftThem() throws {
        let original = profile(mcpRead: true, mcpWrite: false, noApproval: false)
        let edited = try MCPConnectionPolicy.apply(
            MCPConnectionChanges(name: "Renamed", host: "elsewhere"), to: original)
        XCTAssertEqual(edited.mcpRead, original.mcpRead)
        XCTAssertEqual(edited.mcpWrite, original.mcpWrite)
        XCTAssertEqual(edited.mcpWriteWithoutApproval, original.mcpWriteWithoutApproval)
        XCTAssertFalse(edited.allowsMCPWrite)
    }

    func testDuplicateDropsMCPAccessEvenWhenTheOriginalHadItAll() {
        let original = profile(mcpRead: true, mcpWrite: true, noApproval: true)
        let copy = MCPConnectionPolicy.duplicateProfile(original, name: nil)
        XCTAssertFalse(copy.allowsMCPRead)
        XCTAssertFalse(copy.allowsMCPWrite)
        XCTAssertFalse(copy.allowsMCPWriteWithoutApproval)
        // Nothing lingers underneath the computed accessors either.
        XCTAssertNil(copy.mcpRead)
        XCTAssertNil(copy.mcpWrite)
        XCTAssertNil(copy.mcpWriteWithoutApproval)
        XCTAssertNil(copy.mcpAccess)
    }

    func testDuplicateGetsAFreshIdButKeepsTheTarget() {
        let original = profile()
        let copy = MCPConnectionPolicy.duplicateProfile(original, name: nil)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.host, original.host)
        XCTAssertEqual(copy.port, original.port)
        XCTAssertEqual(copy.database, original.database)
        XCTAssertEqual(copy.username, original.username)
        XCTAssertEqual(copy.name, original.name, "no name given keeps the original's")
    }

    func testDuplicateHonoursAnExplicitNameButIgnoresBlankOnes() {
        let original = profile()
        XCTAssertEqual(MCPConnectionPolicy.duplicateProfile(original, name: "Shop copy").name, "Shop copy")
        XCTAssertEqual(MCPConnectionPolicy.duplicateProfile(original, name: "   ").name, original.name)
    }

    // MARK: A password must never follow a connection to a new target

    func testRetargetingIsDetectedForEveryTargetField() throws {
        let original = profile()
        for changes in [MCPConnectionChanges(host: "evil.example.com"),
                        MCPConnectionChanges(port: 6000),
                        MCPConnectionChanges(database: "other"),
                        MCPConnectionChanges(user: "root")] {
            let edited = try MCPConnectionPolicy.apply(changes, to: original)
            XCTAssertTrue(MCPConnectionPolicy.retargets(from: original, to: edited),
                          "expected \(changes) to count as retargeting")
        }
    }

    func testCosmeticEditsDoNotCountAsRetargeting() throws {
        let original = profile()
        let edited = try MCPConnectionPolicy.apply(
            MCPConnectionChanges(name: "Nicer name", readOnly: true, color: "blue"), to: original)
        XCTAssertFalse(MCPConnectionPolicy.retargets(from: original, to: edited))
        XCTAssertEqual(edited.name, "Nicer name")
        XCTAssertTrue(edited.isReadOnly)
    }

    func testChangingSSHCountsAsRetargeting() {
        var original = profile()
        original.ssh = SSHConfig(host: "bastion", username: "me", authMethod: .password)
        var moved = original
        moved.ssh = SSHConfig(host: "other-bastion", username: "me", authMethod: .password)
        XCTAssertTrue(MCPConnectionPolicy.retargets(from: original, to: moved))
    }

    // MARK: Validation

    func testRejectsUnknownEngineAndEmptyFields() {
        XCTAssertThrowsError(try MCPConnectionPolicy.makeProfile(
            MCPConnectionSpec(name: "X", engine: "oracle", host: "h", database: "d", user: "u")))
        XCTAssertThrowsError(try MCPConnectionPolicy.makeProfile(
            MCPConnectionSpec(name: "  ", engine: "postgres", host: "h", database: "d", user: "u")))
        XCTAssertThrowsError(try MCPConnectionPolicy.makeProfile(
            MCPConnectionSpec(name: "X", engine: "postgres", host: " ", database: "d", user: "u")))
    }

    func testEngineAndDefaultsAreApplied() throws {
        let created = try MCPConnectionPolicy.makeProfile(
            MCPConnectionSpec(name: "My DB", engine: "MySQL", host: "h", database: "d", user: "u"))
        XCTAssertEqual(created.kind, .mysql)
        XCTAssertEqual(created.port, DatabaseKind.mysql.defaultPort)
        XCTAssertEqual(created.tlsMode, .prefer)
        XCTAssertFalse(created.isReadOnly)
    }

    func testAccessLabel() {
        XCTAssertEqual(MCPConnectionPolicy.accessLabel(profile()), "write-without-approval")
        XCTAssertEqual(MCPConnectionPolicy.accessLabel(profile(noApproval: false)), "write")
        XCTAssertEqual(MCPConnectionPolicy.accessLabel(
            profile(mcpWrite: false, noApproval: false)), "read")
        XCTAssertEqual(MCPConnectionPolicy.accessLabel(
            profile(mcpRead: false, mcpWrite: false, noApproval: false)), "none")
    }
}
