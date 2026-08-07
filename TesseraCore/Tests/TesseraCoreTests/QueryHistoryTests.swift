import XCTest
@testable import DBPersistence

final class QueryHistoryTests: XCTestCase {

    func testAppendPrependsAndPersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueryHistoryStore(fileURL: url)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.append(QueryHistoryEntry(sql: "SELECT 1", connectionName: "a", timestamp: now, rowCount: 1, elapsedMS: 5))
        store.append(QueryHistoryEntry(sql: "SELECT 2", connectionName: "a", timestamp: now, rowCount: 2, elapsedMS: 6))

        // Reload from a fresh store to prove persistence + date round-trip.
        let reloaded = QueryHistoryStore(fileURL: url).load()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.first?.sql, "SELECT 2") // newest first
        XCTAssertEqual(reloaded.first?.rowCount, 2)
        XCTAssertEqual(reloaded.last?.elapsedMS, 5)
    }

    func testCapEnforced() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueryHistoryStore(fileURL: url, limit: 3)
        for i in 0..<5 {
            store.append(QueryHistoryEntry(sql: "q\(i)", connectionName: "a", timestamp: Date(timeIntervalSince1970: 0)))
        }
        XCTAssertEqual(store.load().count, 3)
        XCTAssertEqual(store.load().first?.sql, "q4")
    }

    // MARK: Per-connection cap

    private func entry(_ sql: String, _ profileID: UUID?, table: String? = nil) -> QueryHistoryEntry {
        QueryHistoryEntry(sql: sql, connectionName: "c", profileID: profileID,
                          table: table, timestamp: Date(timeIntervalSince1970: 0))
    }

    func testPerConnectionCapDoesNotEvictOtherConnections() {
        let busy = UUID(), quiet = UUID()
        var entries = [entry("quiet", quiet)]
        // Newest first: the busy connection floods the head of the list.
        for i in 0..<50 { entries.insert(entry("busy\(i)", busy), at: 0) }

        let capped = QueryHistoryStore.capped(entries, perConnection: 30, total: 2000)

        XCTAssertEqual(capped.filter { $0.profileID == busy }.count, 30)
        XCTAssertEqual(capped.filter { $0.profileID == quiet }.map(\.sql), ["quiet"])
        XCTAssertEqual(capped.first?.sql, "busy49")   // newest kept, oldest dropped
        XCTAssertFalse(capped.contains { $0.sql == "busy19" })
    }

    func testTotalCapStillApplies() {
        let entries = (0..<10).map { entry("q\($0)", UUID()) }   // each its own connection
        let capped = QueryHistoryStore.capped(entries, perConnection: 30, total: 4)
        XCTAssertEqual(capped.map(\.sql), ["q0", "q1", "q2", "q3"])
    }

    func testLegacyEntriesShareOneBucket() {
        let entries = (0..<5).map { entry("q\($0)", nil) }
        XCTAssertEqual(QueryHistoryStore.capped(entries, perConnection: 2, total: 100).count, 2)
    }

    func testEntriesForConnectionExcludesLegacy() {
        let a = UUID(), b = UUID()
        let entries = [entry("a1", a), entry("b1", b), entry("old", nil)]

        XCTAssertEqual(QueryHistoryStore.entries(entries, for: a).map(\.sql), ["a1"])
        // No connection given means "everything", legacy entries included.
        XCTAssertEqual(QueryHistoryStore.entries(entries, for: nil).count, 3)
    }

    func testNewestIndexSkipsOtherConnections() {
        let a = UUID(), b = UUID()
        let entries = [entry("SELECT 1", b), entry("SELECT 1", a)]

        XCTAssertEqual(QueryHistoryStore.newestIndex(in: entries, profileID: a,
                                                     sql: "SELECT 1", table: nil), 1)
        XCTAssertNil(QueryHistoryStore.newestIndex(in: entries, profileID: a,
                                                   sql: "SELECT 2", table: nil))
        // A table view and a typed query with the same SQL are separate entries.
        let mixed = [entry("SELECT *", a, table: "users"), entry("SELECT *", a)]
        XCTAssertEqual(QueryHistoryStore.newestIndex(in: mixed, profileID: a,
                                                     sql: "SELECT *", table: nil), 1)
    }

    func testRemovingConnectionLeavesTheRest() {
        let a = UUID(), b = UUID()
        let entries = [entry("a1", a), entry("b1", b), entry("old", nil)]
        XCTAssertEqual(QueryHistoryStore.removing(entries, profileID: a).map(\.sql), ["b1", "old"])
    }
}
