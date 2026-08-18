import XCTest
@testable import DBKit

final class ConnectionAccessTests: XCTestCase {

    private func profile(readOnly: Bool = false, mcpRead: Bool = false,
                         mcpWrite: Bool = false, noApproval: Bool = false) -> ConnectionProfile {
        ConnectionProfile(name: "Shop", kind: .postgres, host: "h", database: "d",
                          username: "u", readOnly: readOnly, mcpRead: mcpRead,
                          mcpWrite: mcpWrite, mcpWriteWithoutApproval: noApproval)
    }

    func testTurningReadOnlyOnRevokesMCPWrites() {
        let result = profile(mcpRead: true, mcpWrite: true, noApproval: true).settingReadOnly(true)
        XCTAssertTrue(result.isReadOnly)
        XCTAssertTrue(result.allowsMCPRead)
        XCTAssertFalse(result.allowsMCPWrite)
        XCTAssertNil(result.mcpWrite)
        XCTAssertNil(result.mcpWriteWithoutApproval)
    }

    /// Read access is orthogonal — a read-only connection is still perfectly
    /// readable over MCP.
    func testTurningReadOnlyOnKeepsMCPRead() {
        XCTAssertEqual(MCPAccessLevel(profile: profile(mcpRead: true).settingReadOnly(true)), .read)
    }

    /// Lifting read-only must not hand back write access the user never re-granted.
    func testTurningReadOnlyOffDoesNotRestoreWrites() {
        let restored = profile(mcpRead: true, mcpWrite: true, noApproval: true)
            .settingReadOnly(true)
            .settingReadOnly(false)
        XCTAssertFalse(restored.isReadOnly)
        XCTAssertFalse(restored.allowsMCPWrite)
    }

    func testTurningReadOnlyOffLeavesNoStoredFlag() {
        XCTAssertNil(profile(readOnly: true).settingReadOnly(false).readOnly)
    }

    func testUnrelatedFieldsSurvive() {
        var original = profile(mcpRead: true)
        original.color = "teal"
        let result = original.settingReadOnly(true)
        XCTAssertEqual(result.color, "teal")
        XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.name, original.name)
    }
}
