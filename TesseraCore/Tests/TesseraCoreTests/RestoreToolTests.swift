import XCTest
@testable import DBKit

final class RestoreToolTests: XCTestCase {

    func testDetectsInputFromFileName() {
        XCTAssertEqual(RestoreInput.detect(fileName: "shop.sql"), .plainSQL)
        XCTAssertEqual(RestoreInput.detect(fileName: "shop_2026.sql.gz"), .gzippedSQL)
        XCTAssertEqual(RestoreInput.detect(fileName: "shop.dump"), .pgCustom)
        XCTAssertEqual(RestoreInput.detect(fileName: "SHOP.BACKUP"), .pgCustom)
    }

    func testBinaryChoice() {
        XCTAssertEqual(RestoreTool.binaryName(for: .postgres, input: .plainSQL), "psql")
        XCTAssertEqual(RestoreTool.binaryName(for: .postgres, input: .gzippedSQL), "psql")
        XCTAssertEqual(RestoreTool.binaryName(for: .postgres, input: .pgCustom), "pg_restore")
        XCTAssertEqual(RestoreTool.binaryName(for: .mysql, input: .plainSQL), "mysql")
    }

    func testPsqlPlainFileUsesDashF() {
        let args = RestoreTool.arguments(engine: .postgres, host: "h", port: 5432, user: "u",
                                         database: "db", input: .plainSQL, filePath: "/tmp/a.sql",
                                         options: RestoreOptions())
        XCTAssertTrue(args.contains("-f"))
        XCTAssertTrue(args.contains("/tmp/a.sql"))
        XCTAssertTrue(args.contains("--single-transaction"))
        XCTAssertTrue(args.contains("ON_ERROR_STOP=1"))
    }

    func testPsqlGzippedReadsStdin() {
        let args = RestoreTool.arguments(engine: .postgres, host: "h", port: 5432, user: "u",
                                         database: "db", input: .gzippedSQL, filePath: "/tmp/a.sql.gz",
                                         options: RestoreOptions())
        XCTAssertFalse(args.contains("-f"))               // piped in instead
        XCTAssertFalse(args.contains("/tmp/a.sql.gz"))
        XCTAssertTrue(RestoreInput.gzippedSQL.readsStandardInput)
    }

    func testPgRestoreOptions() {
        let args = RestoreTool.arguments(engine: .postgres, host: "h", port: 5432, user: "u",
                                         database: "db", input: .pgCustom, filePath: "/tmp/a.dump",
                                         options: RestoreOptions(dropBeforeCreate: true))
        XCTAssertTrue(args.contains("--clean"))
        XCTAssertTrue(args.contains("--if-exists"))
        XCTAssertEqual(args.last, "/tmp/a.dump")
    }

    func testMySQLTakesDatabaseAndReadsStdin() {
        let args = RestoreTool.arguments(engine: .mysql, host: "h", port: 3306, user: "u",
                                         database: "shop", input: .plainSQL, filePath: "/tmp/a.sql",
                                         options: RestoreOptions())
        XCTAssertEqual(args.last, "shop")
        XCTAssertFalse(args.contains("/tmp/a.sql"))       // fed on stdin
    }

    func testPasswordInEnvironmentOnly() {
        XCTAssertEqual(RestoreTool.environment(engine: .postgres, password: "s"), ["PGPASSWORD": "s"])
        XCTAssertEqual(RestoreTool.environment(engine: .mysql, password: "s"), ["MYSQL_PWD": "s"])
    }
}
