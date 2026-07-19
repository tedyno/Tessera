import XCTest
@testable import DBKit

final class SQLStatementsTests: XCTestCase {

    private func statement(_ sql: String, cursor: Int) -> String? {
        if case .statement(let s) = SQLStatements.resolve(sql: sql, cursor: cursor) { return s }
        return nil
    }

    func testCursorAfterLastSemicolonRunsLastStatement() {
        let sql = "SELECT * FROM t LIMIT 2;\nSELECT * FROM t LIMIT 200;"
        // Cursor at the very end, past the final ';'.
        XCTAssertEqual(statement(sql, cursor: sql.count), "SELECT * FROM t LIMIT 200")
    }

    func testCursorRightAfterFirstSemicolonRunsFirst() {
        let sql = "SELECT 1;\nSELECT 2;"
        let afterFirst = (sql as NSString).range(of: ";").location + 1
        XCTAssertEqual(statement(sql, cursor: afterFirst), "SELECT 1")
    }

    func testCursorInsideSecondStatement() {
        let sql = "SELECT 1;\nSELECT 2;"
        let inSecond = (sql as NSString).range(of: "SELECT 2").location + 3
        XCTAssertEqual(statement(sql, cursor: inSecond), "SELECT 2")
    }

    func testSingleStatementNoSemicolon() {
        let sql = "SELECT 42"
        XCTAssertEqual(statement(sql, cursor: sql.count), "SELECT 42")
    }

    func testSingleStatementCursorAfterSemicolon() {
        let sql = "SELECT 42;"
        XCTAssertEqual(statement(sql, cursor: sql.count), "SELECT 42")
    }

    func testSemicolonInsideStringIsNotASplit() {
        let sql = "SELECT 'a;b' AS x;"
        XCTAssertEqual(statement(sql, cursor: sql.count), "SELECT 'a;b' AS x")
    }

    func testSubselectIsAmbiguous() {
        let sql = "SELECT * FROM (SELECT id FROM t) sub"
        let inside = (sql as NSString).range(of: "id").location
        if case .ambiguous(let choice) = SQLStatements.resolve(sql: sql, cursor: inside) {
            XCTAssertEqual(choice.subselect, "SELECT id FROM t")
        } else {
            XCTFail("expected ambiguous subselect")
        }
    }
}
