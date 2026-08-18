import XCTest
@testable import DBKit

final class MCPAccessLevelTests: XCTestCase {

    private func profile(readOnly: Bool = false, mcpRead: Bool = false,
                         mcpWrite: Bool = false, noApproval: Bool = false) -> ConnectionProfile {
        ConnectionProfile(name: "Shop", kind: .postgres, host: "h", database: "d",
                          username: "u", readOnly: readOnly, mcpRead: mcpRead,
                          mcpWrite: mcpWrite, mcpWriteWithoutApproval: noApproval)
    }

    // MARK: Reading the current level

    func testLevelOfAFreshProfileIsNone() {
        XCTAssertEqual(MCPAccessLevel(profile: profile()), .none)
    }

    func testLevelReflectsEachGrant() {
        XCTAssertEqual(MCPAccessLevel(profile: profile(mcpRead: true)), .read)
        XCTAssertEqual(MCPAccessLevel(profile: profile(mcpRead: true, mcpWrite: true)), .write)
        XCTAssertEqual(MCPAccessLevel(profile: profile(mcpRead: true, mcpWrite: true,
                                                       noApproval: true)), .writeWithoutApproval)
    }

    /// Read-only caps MCP at reading, so that is what the menu must show ticked —
    /// not the write flag left over from before the connection went read-only.
    func testReadOnlyProfileWithStaleWriteFlagsReportsRead() {
        let stale = profile(readOnly: true, mcpRead: true, mcpWrite: true, noApproval: true)
        XCTAssertEqual(MCPAccessLevel(profile: stale), .read)
    }

    func testLegacyAccessFlagCountsAsRead() {
        var legacy = profile()
        legacy.mcpAccess = true
        XCTAssertEqual(MCPAccessLevel(profile: legacy), .read)
    }

    // MARK: Applying a level

    func testApplyingNoneRevokesEverythingIncludingTheLegacyFlag() {
        var target = profile(mcpRead: true, mcpWrite: true, noApproval: true)
        target.mcpAccess = true
        MCPAccessLevel.none.apply(to: &target)
        XCTAssertFalse(target.allowsMCPRead)
        XCTAssertFalse(target.allowsMCPWrite)
        XCTAssertFalse(target.allowsMCPWriteWithoutApproval)
        XCTAssertNil(target.mcpAccess)
    }

    func testApplyingReadDropsWriteButKeepsReadOnly() {
        let result = MCPAccessLevel.read.applied(to: profile(readOnly: true, mcpRead: true,
                                                             mcpWrite: true, noApproval: true))
        XCTAssertTrue(result.allowsMCPRead)
        XCTAssertFalse(result.allowsMCPWrite)
        XCTAssertTrue(result.isReadOnly)
    }

    /// Granting writes has to clear read-only, or the grant would be silently
    /// ignored by `allowsMCPWrite`.
    func testApplyingWriteClearsReadOnly() {
        let result = MCPAccessLevel.write.applied(to: profile(readOnly: true))
        XCTAssertFalse(result.isReadOnly)
        XCTAssertTrue(result.allowsMCPRead)
        XCTAssertTrue(result.allowsMCPWrite)
        XCTAssertFalse(result.allowsMCPWriteWithoutApproval)
    }

    func testApplyingWriteWithoutApprovalGrantsTheWholeChain() {
        let result = MCPAccessLevel.writeWithoutApproval.applied(to: profile(readOnly: true))
        XCTAssertFalse(result.isReadOnly)
        XCTAssertTrue(result.allowsMCPWriteWithoutApproval)
    }

    func testDroppingFromNoApprovalToWriteKeepsApprovalOn() {
        let result = MCPAccessLevel.write.applied(to: profile(mcpRead: true, mcpWrite: true,
                                                              noApproval: true))
        XCTAssertTrue(result.allowsMCPWrite)
        XCTAssertFalse(result.allowsMCPWriteWithoutApproval)
    }

    func testEveryLevelRoundTrips() {
        for level in MCPAccessLevel.allCases {
            let applied = level.applied(to: profile())
            XCTAssertEqual(MCPAccessLevel(profile: applied), level)
        }
    }

    /// Nothing outside the MCP flags moves — the menu must not, say, reset a colour.
    func testApplyingLeavesUnrelatedFieldsAlone() {
        var original = profile()
        original.color = "teal"
        let result = MCPAccessLevel.write.applied(to: original)
        XCTAssertEqual(result.color, "teal")
        XCTAssertEqual(result.name, original.name)
        XCTAssertEqual(result.id, original.id)
    }
}
