import XCTest
@testable import DBKit

final class SQLScriptTests: XCTestCase {

    func testSplitsSimpleStatements() {
        let sql = "SELECT 1; SELECT 2;\nSELECT 3"
        XCTAssertEqual(SQLScript.statements(in: sql), ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    func testIgnoresTrailingEmpty() {
        XCTAssertEqual(SQLScript.statements(in: "SELECT 1;   ;\n"), ["SELECT 1"])
        XCTAssertEqual(SQLScript.statements(in: ""), [])
    }

    func testSemicolonInsideStringLiteral() {
        let sql = "INSERT INTO t VALUES ('a; b'); SELECT 1"
        XCTAssertEqual(SQLScript.statements(in: sql), ["INSERT INTO t VALUES ('a; b')", "SELECT 1"])
    }

    func testEscapedQuoteInString() {
        let sql = "SELECT 'it''s; fine'; SELECT 2"
        XCTAssertEqual(SQLScript.statements(in: sql), ["SELECT 'it''s; fine'", "SELECT 2"])
    }

    func testLineComment() {
        let sql = "SELECT 1; -- a; comment\nSELECT 2"
        XCTAssertEqual(SQLScript.statements(in: sql), ["SELECT 1", "-- a; comment\nSELECT 2"])
    }

    func testBlockComment() {
        let sql = "SELECT 1 /* a; b */; SELECT 2"
        XCTAssertEqual(SQLScript.statements(in: sql), ["SELECT 1 /* a; b */", "SELECT 2"])
    }

    func testDollarQuotedFunctionBody() {
        let sql = """
        CREATE FUNCTION f() RETURNS int AS $$
        BEGIN
            RETURN 1; -- semicolons inside stay together
        END;
        $$ LANGUAGE plpgsql;
        SELECT f()
        """
        let statements = SQLScript.statements(in: sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains("RETURN 1;"))
        XCTAssertTrue(statements[0].contains("END;"))
        XCTAssertEqual(statements[1], "SELECT f()")
    }

    func testNamedDollarTag() {
        let sql = "SELECT $body$ has ; inside $body$; SELECT 2"
        let statements = SQLScript.statements(in: sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains("has ; inside"))
    }
}
