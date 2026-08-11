import XCTest
@testable import DBKit

/// Replays a canned sequence of SCAN pages and counts the round trips, so the
/// paging rules can be checked without a server.
private actor StubKeyValueDriver: KeyValueDriver {
    private let pages: [(cursor: String, keys: [RedisKeyInfo])]
    private(set) var calls = 0

    init(_ pages: [(cursor: String, keys: [RedisKeyInfo])]) {
        self.pages = pages
    }

    func scanKeys(matching pattern: String, cursor: String,
                  count: Int) async throws -> (cursor: String, keys: [RedisKeyInfo]) {
        defer { calls += 1 }
        return calls < pages.count ? pages[calls] : ("0", [])
    }

    func deleteKeys(_ keys: [String]) async throws -> Int { keys.count }
}

private func keys(_ names: String...) -> [RedisKeyInfo] {
    names.map { RedisKeyInfo(key: $0, type: "string") }
}

final class RedisKeyScanTests: XCTestCase {

    // MARK: Database index

    func testEmptyMeansDatabaseZero() throws {
        XCTAssertEqual(try RedisDatabaseIndex.parse(""), 0)
        XCTAssertEqual(try RedisDatabaseIndex.parse("   "), 0)
    }

    func testParsesANumericIndexIgnoringSurroundingSpace() throws {
        XCTAssertEqual(try RedisDatabaseIndex.parse("0"), 0)
        XCTAssertEqual(try RedisDatabaseIndex.parse("3"), 3)
        XCTAssertEqual(try RedisDatabaseIndex.parse(" 15 "), 15)
    }

    func testRejectsAnythingThatIsNotAnIndex() {
        // These used to fall through Int(…) ?? 0 and connect to db0, leaving the
        // user browsing a keyspace they never asked for.
        for text in ["one", "appdb", "1.5", "-1", "0x2", "1 2"] {
            XCTAssertThrowsError(try RedisDatabaseIndex.parse(text), text)
            XCTAssertFalse(RedisDatabaseIndex.isValid(text), text)
        }
    }

    func testValidityMatchesParsing() {
        XCTAssertTrue(RedisDatabaseIndex.isValid(""))
        XCTAssertTrue(RedisDatabaseIndex.isValid("7"))
    }

    // MARK: Scan paging

    func testKeepsScanningPastEmptyPages() async throws {
        // SCAN filters MATCH after picking its slice, so a selective pattern
        // returns empty pages for many cursors before the first hit. One SCAN
        // per page showed "no keys" for a filter that matches plenty.
        let driver = StubKeyValueDriver([
            ("17", []), ("42", []), ("99", keys("user:1", "user:2")),
        ])
        let page = try await driver.scanPage(matching: "user:*", cursor: "0", target: 2)
        XCTAssertEqual(page.keys.map(\.key), ["user:1", "user:2"])
        XCTAssertEqual(page.cursor, "99")
        let calls = await driver.calls
        XCTAssertEqual(calls, 3)
    }

    func testStopsAtTheEndOfTheKeyspace() async throws {
        let driver = StubKeyValueDriver([("5", []), ("0", keys("a"))])
        let page = try await driver.scanPage(matching: "*", cursor: "0", target: 100)
        XCTAssertEqual(page.cursor, "0")
        XCTAssertEqual(page.keys.map(\.key), ["a"])
        let calls = await driver.calls
        XCTAssertEqual(calls, 2, "a \"0\" cursor ends the scan")
    }

    func testStopsOnceThePageIsFull() async throws {
        let driver = StubKeyValueDriver([("7", keys("a", "b")), ("9", keys("c"))])
        let page = try await driver.scanPage(matching: "*", cursor: "0", target: 2)
        XCTAssertEqual(page.keys.map(\.key), ["a", "b"])
        XCTAssertEqual(page.cursor, "7")
        let calls = await driver.calls
        XCTAssertEqual(calls, 1)
    }

    func testGivesUpAfterTheRoundTripBudget() async throws {
        // A pattern matching nothing must not walk the whole keyspace before
        // the UI updates; a non-"0" cursor already reads as "there is more".
        let driver = StubKeyValueDriver(Array(repeating: ("3", []), count: 50))
        let page = try await driver.scanPage(matching: "nope:*", cursor: "0",
                                             target: 10, maxRounds: 4)
        XCTAssertTrue(page.keys.isEmpty)
        XCTAssertEqual(page.cursor, "3")
        let calls = await driver.calls
        XCTAssertEqual(calls, 4)
    }

    func testResumesFromTheGivenCursor() async throws {
        let driver = StubKeyValueDriver([("0", keys("z"))])
        let page = try await driver.scanPage(matching: "*", cursor: "12", target: 10)
        XCTAssertEqual(page.keys.map(\.key), ["z"])
        XCTAssertEqual(page.cursor, "0")
    }
}
