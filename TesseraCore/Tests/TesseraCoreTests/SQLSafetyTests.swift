import XCTest
@testable import DBKit

final class SQLSafetyTests: XCTestCase {

    func testFlagsDeleteWithoutWhere() {
        let warnings = SQLSafety.warnings(in: "DELETE FROM customers;")
        XCTAssertEqual(warnings.map(\.risk), [.deleteWithoutWhere])
    }

    func testAllowsDeleteWithWhere() {
        XCTAssertTrue(SQLSafety.warnings(in: "DELETE FROM customers WHERE id = 3;").isEmpty)
    }

    func testFlagsUpdateWithoutWhere() {
        XCTAssertEqual(SQLSafety.warnings(in: "UPDATE t SET a = 1").map(\.risk), [.updateWithoutWhere])
        XCTAssertTrue(SQLSafety.warnings(in: "UPDATE t SET a = 1 WHERE id = 2").isEmpty)
    }

    func testFlagsDropAndTruncate() {
        XCTAssertEqual(SQLSafety.warnings(in: "DROP TABLE orders;").map(\.risk), [.drop])
        XCTAssertEqual(SQLSafety.warnings(in: "TRUNCATE orders;").map(\.risk), [.truncate])
        XCTAssertEqual(SQLSafety.warnings(in: "DROP DATABASE shop;").map(\.risk), [.drop])
    }

    func testIgnoresCommentsAndStrings() {
        XCTAssertTrue(SQLSafety.warnings(in: "-- DROP TABLE orders\nSELECT 1;").isEmpty)
        XCTAssertTrue(SQLSafety.warnings(in: "SELECT 'DELETE FROM everything';").isEmpty)
        XCTAssertTrue(SQLSafety.warnings(in: "/* TRUNCATE t */ SELECT 1;").isEmpty)
    }

    func testFindsWarningAmongSeveralStatements() {
        let sql = "SELECT 1; DELETE FROM logs; SELECT 2;"
        let warnings = SQLSafety.warnings(in: sql)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.statement, "DELETE FROM logs")
    }

    func testSelectIsSafe() {
        XCTAssertTrue(SQLSafety.warnings(in: "SELECT * FROM customers LIMIT 10;").isEmpty)
    }
}
