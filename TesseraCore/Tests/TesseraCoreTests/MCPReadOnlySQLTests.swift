import XCTest
@testable import DBKit

final class MCPSQLPolicyTests: XCTestCase {

    private func access(_ sql: String) throws -> MCPSQLPolicy.Access {
        try MCPSQLPolicy.classify(sql).access
    }

    func testPlainReadsAreReadOnly() throws {
        XCTAssertEqual(try access("SELECT * FROM customers LIMIT 10"), .readOnly)
        XCTAssertEqual(try access("select id, name from t where id = 3;"), .readOnly)
        XCTAssertEqual(try access("EXPLAIN SELECT 1"), .readOnly)
        XCTAssertEqual(try access("SHOW TABLES"), .readOnly)
        XCTAssertEqual(try access("WITH x AS (SELECT 1) SELECT * FROM x"), .readOnly)
    }

    func testWritesAreClassifiedAsWrite() throws {
        for sql in ["INSERT INTO t VALUES (1)", "UPDATE t SET a = 1", "DELETE FROM t",
                    "DROP TABLE t", "TRUNCATE t", "ALTER TABLE t ADD COLUMN a int",
                    "CREATE TABLE t (a int)", "GRANT ALL ON t TO x"] {
            XCTAssertEqual(try access(sql), .write, "should need approval: \(sql)")
        }
    }

    func testDataModifyingCTECountsAsWrite() throws {
        XCTAssertEqual(try access("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x"), .write)
    }

    func testSelectIntoAndOutfileCountAsWrite() throws {
        // Both create objects / write files despite starting with SELECT.
        XCTAssertEqual(try access("SELECT * INTO backup FROM t"), .write)
        XCTAssertEqual(try access("SELECT * FROM t INTO OUTFILE '/tmp/x'"), .write)
    }

    func testMultipleStatementsAreRefused() {
        XCTAssertThrowsError(try MCPSQLPolicy.classify("SELECT 1; DROP TABLE t;"))
        XCTAssertThrowsError(try MCPSQLPolicy.classify("SELECT 1; SELECT 2"))
    }

    func testKeywordsInsideStringsAndCommentsAreIgnored() throws {
        XCTAssertEqual(try access("SELECT 'DELETE FROM everything' AS note"), .readOnly)
        XCTAssertEqual(try access("SELECT * FROM t -- DROP TABLE t"), .readOnly)
    }

    func testColumnNamesResemblingKeywordsStayReadOnly() throws {
        XCTAssertEqual(try access("SELECT created_at, updated_at FROM t"), .readOnly)
    }

    func testEmptyIsRefused() {
        XCTAssertThrowsError(try MCPSQLPolicy.classify("   "))
    }

    func testIsReadOnlyConvenience() {
        XCTAssertTrue(MCPSQLPolicy.isReadOnly("SELECT 1"))
        XCTAssertFalse(MCPSQLPolicy.isReadOnly("DELETE FROM t"))
        XCTAssertFalse(MCPSQLPolicy.isReadOnly("SELECT 1; SELECT 2"))
    }
}
