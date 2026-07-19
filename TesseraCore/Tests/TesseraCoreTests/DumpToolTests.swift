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
                              "--no-password", "--no-owner", "shop"])
    }

    func testPostgresSchemaOnlyAndScope() {
        let structure = DumpTool.arguments(kind: .postgres, host: "h", port: 5432, user: "u",
                                           database: "db",
                                           options: DumpOptions(scope: .schema("public"),
                                                                includeStructure: true, includeData: false))
        XCTAssertTrue(structure.contains("--schema-only"))
        XCTAssertTrue(structure.contains("--schema=public"))
        XCTAssertFalse(structure.contains("--data-only"))
    }

    func testPostgresSelectedTables() {
        let args = DumpTool.arguments(kind: .postgres, host: "h", port: 5432, user: "u", database: "db",
                                      options: DumpOptions(scope: .tables(schema: "public",
                                                                          tables: ["orders", "customers"])))
        XCTAssertTrue(args.contains("--table=public.orders"))
        XCTAssertTrue(args.contains("--table=public.customers"))
    }

    func testMySQLDataOnlyAndTables() {
        let dataOnly = DumpTool.arguments(kind: .mysql, host: "h", port: 3306, user: "u", database: "shop",
                                          options: DumpOptions(includeStructure: false, includeData: true))
        XCTAssertTrue(dataOnly.contains("--no-create-info"))
        XCTAssertTrue(dataOnly.contains("shop"))

        let tables = DumpTool.arguments(kind: .mysql, host: "h", port: 3306, user: "u", database: "shop",
                                        options: DumpOptions(scope: .tables(schema: "shop", tables: ["orders"])))
        XCTAssertEqual(tables.last, "orders")
        XCTAssertTrue(tables.contains("shop"))
    }
}
