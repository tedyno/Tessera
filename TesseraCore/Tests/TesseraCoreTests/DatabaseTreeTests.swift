import XCTest
@testable import DBKit

final class DatabaseTreeTests: XCTestCase {

    /// public.users(id) ← public.orders(customer_id), audit.logs(user_id);
    /// public.orders(id) has no incoming references.
    private var tree: DatabaseTree {
        let usersID = ForeignKeyTarget(schema: "public", table: "users", column: "id")
        return DatabaseTree(databaseName: "shop", schemas: [
            SchemaNamespace(name: "public", tables: [
                SchemaTable(name: "users", columns: [
                    SchemaColumn(name: "id", dataType: "integer", isPrimaryKey: true),
                    SchemaColumn(name: "name", dataType: "text"),
                ]),
                SchemaTable(name: "orders", columns: [
                    SchemaColumn(name: "id", dataType: "integer", isPrimaryKey: true),
                    SchemaColumn(name: "customer_id", dataType: "integer",
                                 isForeignKey: true, references: usersID),
                ]),
            ]),
            SchemaNamespace(name: "audit", tables: [
                SchemaTable(name: "logs", columns: [
                    SchemaColumn(name: "user_id", dataType: "integer",
                                 isForeignKey: true, references: usersID),
                ]),
            ]),
        ])
    }

    func testFindsReferencingColumnsAcrossSchemas() {
        let origins = tree.incomingReferences(toSchema: "public", table: "users", column: "id")
        XCTAssertEqual(origins, [
            ForeignKeyTarget(schema: "public", table: "orders", column: "customer_id"),
            ForeignKeyTarget(schema: "audit", table: "logs", column: "user_id"),
        ])
    }

    func testUnreferencedColumnHasNoIncomingReferences() {
        XCTAssertTrue(tree.incomingReferences(toSchema: "public", table: "orders",
                                              column: "id").isEmpty)
        XCTAssertTrue(tree.incomingReferences(toSchema: "public", table: "users",
                                              column: "name").isEmpty)
    }

    func testMatchesExactSchemaTableAndColumn() {
        // Same table/column name in another schema must not match.
        XCTAssertTrue(tree.incomingReferences(toSchema: "audit", table: "users",
                                              column: "id").isEmpty)
    }

    func testSelfReferenceIsFound() {
        let employees = SchemaTable(name: "employees", columns: [
            SchemaColumn(name: "id", dataType: "integer", isPrimaryKey: true),
            SchemaColumn(name: "manager_id", dataType: "integer", isForeignKey: true,
                         references: ForeignKeyTarget(schema: "public", table: "employees",
                                                      column: "id")),
        ])
        let tree = DatabaseTree(databaseName: "hr", schemas: [
            SchemaNamespace(name: "public", tables: [employees]),
        ])
        XCTAssertEqual(tree.incomingReferences(toSchema: "public", table: "employees",
                                               column: "id"),
                       [ForeignKeyTarget(schema: "public", table: "employees",
                                         column: "manager_id")])
    }
}
