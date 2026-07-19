import XCTest
@testable import DBKit

final class DumpToolTests: XCTestCase {

    func testBinaryNames() {
        XCTAssertEqual(DumpTool.binaryName(for: .postgres), "pg_dump")
        XCTAssertEqual(DumpTool.binaryName(for: .mysql), "mysqldump")
    }

    func testMajorVersionParsing() {
        XCTAssertEqual(DumpTool.majorVersion("pg_dump (PostgreSQL) 16.2"), 16)
        XCTAssertEqual(DumpTool.majorVersion("mysqldump  Ver 8.0.35 for macos13.0 on arm64"), 8)
        XCTAssertEqual(DumpTool.majorVersion("15.4"), 15)
        XCTAssertNil(DumpTool.majorVersion("no digits here"))
    }

    func testPasswordGoesToEnvironmentNotArgs() {
        XCTAssertEqual(DumpTool.environment(kind: .postgres, password: "secret"), ["PGPASSWORD": "secret"])
        XCTAssertEqual(DumpTool.environment(kind: .mysql, password: "secret"), ["MYSQL_PWD": "secret"])
        XCTAssertEqual(DumpTool.environment(kind: .postgres, password: nil), [:])
        let args = DumpTool.arguments(kind: .postgres, host: "h", port: 5432, user: "u",
                                      database: "db", options: DumpOptions())
        XCTAssertFalse(args.contains { $0.contains("secret") })
    }

    func testPostgresWholeDatabase() {
        let args = DumpTool.arguments(kind: .postgres, host: "localhost", port: 5432, user: "me",
                                      database: "shop", options: DumpOptions())
        XCTAssertEqual(args, ["--host=localhost", "--port=5432", "--username=me",
                              "--no-password", "--no-owner", "--format=plain", "shop"])
    }

    func testPostgresOptions() {
        let options = DumpOptions(schemas: ["public"], includeStructure: true, includeData: false,
                                  dropBeforeCreate: true, dropIfExists: true, createDatabase: true,
                                  useInsertStatements: true)
        let args = DumpTool.arguments(kind: .postgres, host: "h", port: 5432, user: "u",
                                      database: "db", options: options)
        XCTAssertTrue(args.contains("--schema-only"))
        XCTAssertTrue(args.contains("--schema=public"))
        XCTAssertTrue(args.contains("--clean"))
        XCTAssertTrue(args.contains("--if-exists"))
        XCTAssertTrue(args.contains("--create"))
        XCTAssertTrue(args.contains("--inserts"))
    }

    func testPostgresTableQualifiedWithSingleSchema() {
        let options = DumpOptions(schemas: ["public"], tables: ["orders"])
        let args = DumpTool.arguments(kind: .postgres, host: "h", port: 5432, user: "u", database: "db", options: options)
        XCTAssertTrue(args.contains("--table=public.orders"))
    }

    func testPostgresCustomFormat() {
        let options = DumpOptions(format: .custom)
        let args = DumpTool.arguments(kind: .postgres, host: "h", port: 5432, user: "u", database: "db", options: options)
        XCTAssertTrue(args.contains("--format=custom"))
    }

    func testMySQLOptions() {
        let options = DumpOptions(includeStructure: false, includeData: true,
                                  dropBeforeCreate: true, useInsertStatements: true)
        let args = DumpTool.arguments(kind: .mysql, host: "h", port: 3306, user: "u", database: "shop", options: options)
        XCTAssertTrue(args.contains("--no-create-info"))
        XCTAssertTrue(args.contains("--add-drop-table"))
        XCTAssertTrue(args.contains("--complete-insert"))
        XCTAssertTrue(args.contains("--skip-extended-insert"))
        XCTAssertTrue(args.contains("shop"))
    }

    func testMySQLTablesAndCreateDatabase() {
        let tables = DumpTool.arguments(kind: .mysql, host: "h", port: 3306, user: "u", database: "shop",
                                        options: DumpOptions(tables: ["orders"]))
        XCTAssertEqual(tables.last, "orders")

        let createDb = DumpTool.arguments(kind: .mysql, host: "h", port: 3306, user: "u", database: "shop",
                                          options: DumpOptions(createDatabase: true))
        XCTAssertTrue(createDb.contains("--databases"))
        XCTAssertEqual(createDb.last, "shop")
    }
}
