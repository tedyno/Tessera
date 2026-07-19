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
}
