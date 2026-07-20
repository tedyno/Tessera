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
        try? FileManager.default.removeItem(at: store.fileURL)
    }

    func testMissingFileIsEmptyNotAFailure() {
        let store = SchemaCacheStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-cache-does-not-exist.json"))
        XCTAssertTrue(store.load().isEmpty)
    }
}
