import XCTest
@testable import DBKit

/// Whatever this splits out is what gets sent to the user's database, so the
/// boundaries matter more than the formatting.
final class SQLBatchTests: XCTestCase {

    private func steps(_ sql: String, select range: NSRange) -> [String] {
        SQLBatch.statements(in: sql, selectedUTF16Range: range).map { $0 }
    }

    func testSelectionCoveringSeveralStatementsSplitsOnSemicolons() {
        let sql = "SELECT 1; UPDATE t SET a = 1; SELECT 2;"
        let all = NSRange(location: 0, length: (sql as NSString).length)
        XCTAssertEqual(steps(sql, select: all),
                       ["SELECT 1", "UPDATE t SET a = 1", "SELECT 2"])
    }

    func testEmptySelectionRunsNothing() {
        XCTAssertTrue(steps("SELECT 1; SELECT 2;", select: NSRange(location: 3, length: 0)).isEmpty)
    }

    /// Selecting part of one statement stays one statement — the long-standing
    /// "highlight a fragment and run it" behavior must not turn into a batch.
    func testSelectionInsideOneStatementYieldsThatFragment() {
        let sql = "SELECT id, name FROM users"
        let range = NSRange(location: 0, length: 9)   // "SELECT id"
        XCTAssertEqual(steps(sql, select: range), ["SELECT id"])
    }

    func testSemicolonInsideAStringIsNotASeparator() {
        let sql = "INSERT INTO t VALUES ('a;b'); SELECT 1"
        let all = NSRange(location: 0, length: (sql as NSString).length)
        XCTAssertEqual(steps(sql, select: all), ["INSERT INTO t VALUES ('a;b')", "SELECT 1"])
    }

    func testTrailingSemicolonDoesNotProduceAnEmptyStep() {
        let sql = "SELECT 1;\n"
        let all = NSRange(location: 0, length: (sql as NSString).length)
        XCTAssertEqual(steps(sql, select: all), ["SELECT 1"])
    }

    /// A selection that is only a comment would otherwise be sent as an empty
    /// command and come back as a driver error the user cannot act on.
    func testCommentOnlySelectionRunsNothing() {
        let sql = "-- just a note\n/* and another */"
        let all = NSRange(location: 0, length: (sql as NSString).length)
        XCTAssertTrue(steps(sql, select: all).isEmpty)
    }

    func testCommentBeforeARealStatementIsKept() {
        let sql = "-- explain\nSELECT 1;"
        let all = NSRange(location: 0, length: (sql as NSString).length)
        XCTAssertEqual(steps(sql, select: all), ["-- explain\nSELECT 1"])
    }

    /// Selections come from an AppKit text view, which counts UTF-16 units. Get this
    /// wrong and any emoji or accented text above the selection shifts it.
    func testRangeIsInterpretedAsUTF16() {
        let sql = "SELECT '🎉'; SELECT 2"
        let ns = sql as NSString
        let second = ns.range(of: "SELECT 2")
        XCTAssertEqual(steps(sql, select: second), ["SELECT 2"])
    }

    func testStepsAreNumberedFromOne() {
        let sql = "SELECT 1; SELECT 2"
        let all = NSRange(location: 0, length: (sql as NSString).length)
        XCTAssertEqual(SQLBatch.steps(in: sql, selectedUTF16Range: all).map(\.number), [1, 2])
    }

    // MARK: Labels

    func testLabelCollapsesWhitespaceSoAWrappedStatementIsOneRow() {
        XCTAssertEqual(SQLBatch.label(for: "SELECT\n  id,\n  name\nFROM users"),
                       "SELECT id, name FROM users")
    }

    func testLabelIsTruncatedWithAnEllipsis() {
        let label = SQLBatch.label(for: String(repeating: "a", count: 100), limit: 10)
        XCTAssertEqual(label.count, 10)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    // MARK: Outcome

    func testOutcomeDistinguishesRowsReturnedFromRowsAffected() {
        var select = SQLBatchStep(number: 1, sql: "SELECT 1")
        select.didRun = true
        select.result = QueryResult(columns: [], rows: [[], []], returnsRows: true)
        XCTAssertEqual(select.outcome, .rows(2))

        var update = SQLBatchStep(number: 2, sql: "UPDATE t SET a = 1")
        update.didRun = true
        update.result = QueryResult(columns: [], rows: [], rowsAffected: 7)
        XCTAssertEqual(update.outcome, .affected(7))
    }

    /// A batch stopped by an error must show which statements never ran, or the user
    /// cannot tell what state the database is in.
    func testStatementsAfterAFailureStayPending() {
        var failed = SQLBatchStep(number: 1, sql: "SELECT bad")
        failed.didRun = true
        failed.errorMessage = "column bad does not exist"
        XCTAssertEqual(failed.outcome, .failed("column bad does not exist"))
        XCTAssertEqual(SQLBatchStep(number: 2, sql: "SELECT 1").outcome, .pending)
    }
}
