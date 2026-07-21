import XCTest
@testable import DBKit

final class SchemaDDLTests: XCTestCase {

    func testQuotingPerEngine() {
        XCTAssertEqual(SchemaDDL.quote("order", for: .postgres), "\"order\"")
        XCTAssertEqual(SchemaDDL.quote("order", for: .mysql), "`order`")
        XCTAssertEqual(SchemaDDL.quote("we\"ird", for: .postgres), "\"we\"\"ird\"")
    }

    func testQualifiedNameSkipsSchemaOnMySQL() {
        XCTAssertEqual(SchemaDDL.qualified(schema: "public", table: "t", for: .postgres), "\"public\".\"t\"")
        XCTAssertEqual(SchemaDDL.qualified(schema: "shop", table: "t", for: .mysql), "`t`")
    }

    func testAddColumnWithDefaultAndNotNull() {
        let column = SchemaDDL.ColumnSpec(name: "total", dataType: "numeric(10,2)",
                                          isNullable: false, defaultValue: "0")
        XCTAssertEqual(
            SchemaDDL.addColumn(column, schema: "public", table: "orders", for: .postgres),
            "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"total\" numeric(10,2) DEFAULT 0 NOT NULL;")
    }

    func testDropAndRenameColumn() {
        XCTAssertEqual(SchemaDDL.dropColumn("note", schema: nil, table: "t", for: .mysql),
                       "ALTER TABLE `t` DROP COLUMN `note`;")
        XCTAssertEqual(SchemaDDL.renameColumn(from: "a", to: "b", schema: nil, table: "t", for: .postgres),
                       "ALTER TABLE \"t\" RENAME COLUMN \"a\" TO \"b\";")
    }

    func testChangeColumnTypeDiffersPerEngine() {
        let column = SchemaDDL.ColumnSpec(name: "qty", dataType: "int")
        XCTAssertEqual(SchemaDDL.changeColumnType(column, schema: nil, table: "t", for: .postgres),
                       "ALTER TABLE \"t\" ALTER COLUMN \"qty\" TYPE int;")
        XCTAssertEqual(SchemaDDL.changeColumnType(column, schema: nil, table: "t", for: .mysql),
                       "ALTER TABLE `t` MODIFY COLUMN `qty` int;")
    }

    func testNullabilityChange() {
        XCTAssertEqual(
            SchemaDDL.setColumnNullability("a", isNullable: false, dataType: "text",
                                           schema: nil, table: "t", for: .postgres),
            "ALTER TABLE \"t\" ALTER COLUMN \"a\" SET NOT NULL;")
        XCTAssertTrue(
            SchemaDDL.setColumnNullability("a", isNullable: true, dataType: "text",
                                           schema: nil, table: "t", for: .mysql)
                .contains("MODIFY COLUMN `a` text"))
    }

    func testIndexes() {
        XCTAssertEqual(
            SchemaDDL.createIndex(name: "idx_a", columns: ["a", "b"], unique: true,
                                  schema: "public", table: "t", for: .postgres),
            "CREATE UNIQUE INDEX \"idx_a\" ON \"public\".\"t\" (\"a\", \"b\");")
        XCTAssertEqual(SchemaDDL.dropIndex(name: "idx_a", schema: nil, table: "t", for: .mysql),
                       "ALTER TABLE `t` DROP INDEX `idx_a`;")
        XCTAssertEqual(SchemaDDL.dropIndex(name: "idx_a", schema: "public", table: "t", for: .postgres),
                       "DROP INDEX \"public\".\"idx_a\";")
    }

    func testCreateTableWithPrimaryKey() {
        let sql = SchemaDDL.createTable(
            name: "items", schema: "public",
            columns: [SchemaDDL.ColumnSpec(name: "id", dataType: "serial", isNullable: false),
                      SchemaDDL.ColumnSpec(name: "name", dataType: "text")],
            primaryKey: ["id"], for: .postgres)
        XCTAssertTrue(sql.hasPrefix("CREATE TABLE \"public\".\"items\" ("))
        XCTAssertTrue(sql.contains("\"id\" serial NOT NULL"))
        XCTAssertTrue(sql.contains("PRIMARY KEY (\"id\")"))
    }

    func testDropRenameTruncateTable() {
        XCTAssertEqual(SchemaDDL.dropTable(name: "t", schema: nil, ifExists: true, for: .postgres),
                       "DROP TABLE IF EXISTS \"t\";")
        XCTAssertEqual(SchemaDDL.renameTable(from: "a", to: "b", schema: nil, for: .mysql),
                       "RENAME TABLE `a` TO `b`;")
        XCTAssertEqual(SchemaDDL.truncateTable(name: "t", schema: "public", for: .postgres),
                       "TRUNCATE TABLE \"public\".\"t\";")
    }

    func testMariaDBFollowsMySQL() {
        XCTAssertEqual(SchemaDDL.quote("order", for: .mariadb), "`order`")
        XCTAssertEqual(SchemaDDL.qualified(schema: "shop", table: "t", for: .mariadb), "`t`")
        XCTAssertEqual(SchemaDDL.renameTable(from: "a", to: "b", schema: nil, for: .mariadb),
                       "RENAME TABLE `a` TO `b`;")
        XCTAssertEqual(SchemaDDL.dropIndex(name: "idx_a", schema: nil, table: "t", for: .mariadb),
                       "ALTER TABLE `t` DROP INDEX `idx_a`;")
        let column = SchemaDDL.ColumnSpec(name: "qty", dataType: "int")
        XCTAssertEqual(SchemaDDL.changeColumnType(column, schema: nil, table: "t", for: .mariadb),
                       "ALTER TABLE `t` MODIFY COLUMN `qty` int;")
    }

    func testSQLiteDialectDDL() {
        // Single namespace: never schema-qualified, even when one is passed.
        XCTAssertEqual(SchemaDDL.qualified(schema: "main", table: "t", for: .sqlite), "\"t\"")
        XCTAssertEqual(SchemaDDL.renameTable(from: "a", to: "b", schema: nil, for: .sqlite),
                       "ALTER TABLE \"a\" RENAME TO \"b\";")
        XCTAssertEqual(SchemaDDL.dropIndex(name: "idx_a", schema: "main", table: "t", for: .sqlite),
                       "DROP INDEX \"idx_a\";")
        // No TRUNCATE statement — DELETE FROM is the SQLite idiom.
        XCTAssertEqual(SchemaDDL.truncateTable(name: "t", schema: nil, for: .sqlite),
                       "DELETE FROM \"t\";")
    }

    func testSQLiteUnsupportedOperations() {
        XCTAssertFalse(SchemaDDL.supports(.changeColumnType, for: .sqlite))
        XCTAssertFalse(SchemaDDL.supports(.setNullability, for: .sqlite))
        XCTAssertTrue(SchemaDDL.supports(.addColumn, for: .sqlite))
        XCTAssertTrue(SchemaDDL.supports(.renameColumn, for: .sqlite))
        XCTAssertTrue(SchemaDDL.supports(.changeColumnType, for: .postgres))
        XCTAssertTrue(SchemaDDL.supports(.setNullability, for: .mariadb))
    }
}
