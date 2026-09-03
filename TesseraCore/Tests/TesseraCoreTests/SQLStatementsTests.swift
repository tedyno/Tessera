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

/// The editor computes the split once per edit and resolves the caret against it,
/// so the ranges have to mean exactly what the single-cursor lookup used to.
final class SQLStatementRangesTests: XCTestCase {
    func testSplitsOnTopLevelSemicolons() {
        let sql = "SELECT 1; SELECT 2"
        let ranges = SQLStatements.statementNSRanges(sql: sql)
        XCTAssertEqual(ranges.map { (sql as NSString).substring(with: $0) },
                       ["SELECT 1", " SELECT 2"])
    }

    func testSemicolonsInsideStringsAndCommentsDoNotSplit() {
        let sql = "SELECT ';', 1 -- and; a comment\n; SELECT 2"
        let ranges = SQLStatements.statementNSRanges(sql: sql)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual((sql as NSString).substring(with: ranges[0]),
                       "SELECT ';', 1 -- and; a comment\n")
    }

    func testEscapedQuoteKeepsTheLiteralOpen() {
        let sql = "SELECT 'it''s; fine'; SELECT 2"
        XCTAssertEqual(SQLStatements.statementNSRanges(sql: sql).count, 2)
    }

    func testCursorJustAfterASemicolonBelongsToTheStatementThatEnded() {
        let sql = "SELECT 1; SELECT 2"
        let ranges = SQLStatements.statementNSRanges(sql: sql)
        let range = SQLStatements.statement(at: 9, in: ranges)   // right after the ';'
        XCTAssertEqual(range.map { (sql as NSString).substring(with: $0) }, "SELECT 1")
    }

    /// Past the final `;` the caret still belongs to the statement that just
    /// ended — but an empty one (two semicolons in a row) has nothing to point at.
    func testCursorPastATrailingSemicolonResolvesToTheStatementThatEnded() {
        let sql = "SELECT 1;"
        let ranges = SQLStatements.statementNSRanges(sql: sql)
        XCTAssertEqual(SQLStatements.statement(at: 9, in: ranges).map { (sql as NSString).substring(with: $0) },
                       "SELECT 1")
    }

    func testAnEmptyStatementHasNoRange() {
        let sql = "SELECT 1;;"
        let ranges = SQLStatements.statementNSRanges(sql: sql)
        XCTAssertNil(SQLStatements.statement(at: 10, in: ranges))
    }

    /// Offsets are what the text view indexes with, so a character outside the BMP
    /// has to count as the two UTF-16 units it really is.
    func testOffsetsAreUTF16NotCharacters() {
        let sql = "SELECT '🎉'; SELECT 2"
        let ranges = SQLStatements.statementNSRanges(sql: sql)
        XCTAssertEqual(ranges.map { (sql as NSString).substring(with: $0) },
                       ["SELECT '🎉'", " SELECT 2"])
    }

    /// The whole point of the split: it must agree with the lookup the editor and
    /// ⌘↩ used before, for every caret position in a mixed document.
    func testAgreesWithTheSingleCursorLookupEverywhere() {
        let sql = "SELECT 'a;b' -- x;\n, 2; UPDATE t SET c = 1 WHERE id = 3;\n\nSELECT 4"
        let ranges = SQLStatements.statementNSRanges(sql: sql)
        for cursor in 0...(sql as NSString).length {
            XCTAssertEqual(SQLStatements.statement(at: cursor, in: ranges),
                           SQLStatements.statementNSRange(sql: sql, utf16Cursor: cursor),
                           "cursor \(cursor)")
        }
    }
}
