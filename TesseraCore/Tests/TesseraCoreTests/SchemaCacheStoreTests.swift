import XCTest
@testable import DBPersistence
@testable import DBKit

final class SchemaCacheStoreTests: XCTestCase {
    private func tempStore() -> SchemaCacheStore {
        SchemaCacheStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-cache-\(UUID().uuidString).json"))
    }

    private func sampleTree() -> DatabaseTree {
        DatabaseTree(databaseName: "shop", schemas: [
            SchemaNamespace(name: "public", tables: [
                SchemaTable(name: "orders", kind: .table,
                            columns: [SchemaColumn(name: "customer_id", dataType: "int8",
                                                   isForeignKey: true,
                                                   references: ForeignKeyTarget(schema: "public",
                                                                                table: "customers",
                                                                                column: "id"))],
                            indexes: [SchemaIndex(name: "orders_pkey", columns: ["id"], isUnique: true)]),
            ]),
        ])
    }

    func testRoundTripsTheWholeTree() throws {
        let store = tempStore()
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        store.save([id: CachedSchema(tree: sampleTree(), updatedAt: stamp)])

        let loaded = store.load()
        let entry = try XCTUnwrap(loaded[id])
        XCTAssertEqual(entry.updatedAt.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(entry.tree.databaseName, "shop")

        let table = try XCTUnwrap(entry.tree.schemas.first?.tables.first)
        XCTAssertEqual(table.kind, .table)
        // The foreign-key target must survive; "follow the reference" depends on it.
        XCTAssertEqual(table.columns.first?.references?.table, "customers")
        XCTAssertEqual(table.indexes.first?.isUnique, true)
        try? FileManager.default.removeItem(at: store.directoryURL)
    }

    func testMissingFileIsEmptyNotAFailure() {
        let store = SchemaCacheStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-cache-does-not-exist.json"))
        XCTAssertTrue(store.load().isEmpty)
    }

    /// One connection's refresh must leave every other connection's file alone —
    /// that separation is the whole point of writing them apart.
    func testWritingOneConnectionLeavesTheOthersUntouched() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let kept = UUID(), refreshed = UUID()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        store.save([kept: CachedSchema(tree: sampleTree(), updatedAt: stamp),
                    refreshed: CachedSchema(tree: sampleTree(), updatedAt: stamp)])

        let keptURL = store.directoryURL.appendingPathComponent("\(kept.uuidString).json")
        let before = try FileManager.default.attributesOfItem(atPath: keptURL.path)[.modificationDate] as? Date

        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try XCTUnwrap(store.encode(CachedSchema(tree: sampleTree(), updatedAt: newer)))
        store.write(data, for: refreshed)

        let after = try FileManager.default.attributesOfItem(atPath: keptURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        let loaded = store.load()
        XCTAssertEqual(try XCTUnwrap(loaded[refreshed]).updatedAt.timeIntervalSince1970,
                       newer.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(loaded[kept]).updatedAt.timeIntervalSince1970,
                       stamp.timeIntervalSince1970, accuracy: 1)
    }

    func testRemovingOneConnectionKeepsTheRest() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let kept = UUID(), dropped = UUID()
        store.save([kept: CachedSchema(tree: sampleTree(), updatedAt: Date()),
                    dropped: CachedSchema(tree: sampleTree(), updatedAt: Date())])
        store.remove(dropped)

        let loaded = store.load()
        XCTAssertNil(loaded[dropped])
        XCTAssertNotNil(loaded[kept])
    }

    /// An update must not throw away the cache written by the previous version:
    /// the single file is split into per-connection ones and then retired.
    func testLegacySingleFileIsMigratedAndRemoved() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = try encoder.encode([id.uuidString: CachedSchema(tree: sampleTree(), updatedAt: stamp)])
        try legacy.write(to: store.fileURL)

        let loaded = store.load()
        XCTAssertEqual(loaded[id]?.tree.databaseName, "shop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                       "the migrated file must not be left behind to be re-read")
        // And it survives as a per-connection file, not just in the returned value.
        XCTAssertEqual(try XCTUnwrap(store.load()[id]).updatedAt.timeIntervalSince1970,
                       stamp.timeIntervalSince1970, accuracy: 1)
    }
}

final class PrivateFilePermissionTests: XCTestCase {

    /// The data files hold connection parameters, query history and schema names —
    /// none of it needs to be world-readable, and `644` is the Foundation default.
    func testStoresWriteOwnerOnlyFiles() throws {
        let directory = FileManager.default.temporaryDirectory
        let cache = SchemaCacheStore(fileURL: directory
            .appendingPathComponent("perm-cache-\(UUID().uuidString).json"))
        let history = QueryHistoryStore(fileURL: directory
            .appendingPathComponent("perm-history-\(UUID().uuidString).json"))
        let saved = SavedQueryStore(fileURL: directory
            .appendingPathComponent("perm-saved-\(UUID().uuidString).json"))

        let cachedID = UUID()
        cache.save([cachedID: CachedSchema(tree: DatabaseTree(databaseName: "shop"), updatedAt: Date())])
        history.save([])
        saved.save([])

        let cacheEntry = cache.directoryURL.appendingPathComponent("\(cachedID.uuidString).json")
        for url in [cacheEntry, history.fileURL, saved.fileURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.int16Value, 0o600, "world/group readable: \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: cache.directoryURL)
    }
}
