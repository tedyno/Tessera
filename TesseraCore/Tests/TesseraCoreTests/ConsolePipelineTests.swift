import XCTest
@testable import DBKit

final class ConsolePipelineTests: XCTestCase {

    private let sql = DatabaseKind.postgres.consolePipeline
    private let mysql = DatabaseKind.mysql.consolePipeline
    private let redis = DatabaseKind.redis.consolePipeline

    // MARK: Run units

    func testSQLRunTargetResolvesStatementUnderCursor() {
        let text = "SELECT 1;\nSELECT 2;"
        guard case .statement(let statement) = sql.runTarget(in: text, cursor: text.count - 2)
        else { return XCTFail("expected a statement") }
        XCTAssertTrue(statement.contains("SELECT 2"))
    }

    func testRedisRunTargetIsTheCursorLine() {
        let text = "GET a\nGET b"
        XCTAssertEqual(redis.runTarget(in: text, cursor: 7), .statement("GET b"))
        // A blank cursor line resolves to the nearest command ABOVE — the one
        // just typed — never the top of the buffer (FLUSHDB up there must not
        // run because Enter left the caret on an empty line).
        XCTAssertEqual(redis.runTarget(in: "FLUSHDB\nGET a\n", cursor: 14),
                       .statement("GET a"))
        // Only with nothing above does it fall forward to the first command.
        XCTAssertEqual(redis.runTarget(in: "\n\nGET c", cursor: 0), .statement("GET c"))
    }

    func testRedisFlushCommandsWarn() {
        XCTAssertEqual(redis.safetyWarnings(in: "FLUSHALL").map(\.risk), [.flush])
        XCTAssertEqual(redis.safetyWarnings(in: "flushdb ASYNC").map(\.risk), [.flush])
        XCTAssertTrue(redis.safetyWarnings(in: "DEL user:1").isEmpty,
                      "an explicit DEL names its targets, like DELETE with WHERE")
    }

    func testScriptStatements() {
        XCTAssertEqual(sql.scriptStatements(in: "SELECT 1; SELECT 2;").count, 2)
        XCTAssertEqual(redis.scriptStatements(in: "SET a 1\n\nGET a\n"),
                       ["SET a 1", "GET a"])
    }

    // MARK: SQL-only scans

    func testParameterScanIsSQLOnly() {
        XCTAssertEqual(sql.parameterNames(in: "SELECT * FROM t WHERE id = :id"), ["id"])
        XCTAssertEqual(sql.parameterNames(in: "SELECT 'a:b'::text"), [],
                       "casts and literals are not placeholders")
        // The regression that motivated the pipeline: a Redis key is not a
        // parameter, no matter how many colons it carries.
        XCTAssertEqual(redis.parameterNames(in: "GET session:abc123"), [])
    }

    func testSubstitutionRespectsEngineEscaping() {
        XCTAssertEqual(sql.substituteParameters(in: "WHERE name = :n",
                                                values: ["n": "O'Brien"]),
                       "WHERE name = 'O''Brien'")
        XCTAssertEqual(mysql.substituteParameters(in: "WHERE path = :p",
                                                  values: ["p": #"a\b"#]),
                       #"WHERE path = 'a\\b'"#)
        XCTAssertEqual(redis.substituteParameters(in: "GET session:abc123", values: [:]),
                       "GET session:abc123")
    }

    func testSafetyScanIsSQLOnly() {
        XCTAssertFalse(sql.safetyWarnings(in: "DELETE FROM users").isEmpty)
        XCTAssertTrue(redis.safetyWarnings(in: "DEL users").isEmpty)
        XCTAssertTrue(redis.safetyWarnings(in: "DELETE FROM users").isEmpty,
                      "SQL-looking text is just a Redis command line")
    }

    // MARK: Pre-run rewrite

    private var completion: SQLCompletionEngine {
        SQLCompletionEngine(schema: DatabaseTree(databaseName: "app", schemas: [
            SchemaNamespace(name: "public", tables: [
                SchemaTable(name: "users", columns: [
                    SchemaColumn(name: "status", dataType: "text"),
                ]),
            ]),
        ]), engine: .postgres)
    }

    func testRewriteAutoQuotesSQLOnly() {
        XCTAssertEqual(
            sql.rewriteForRun("SELECT * FROM users WHERE status = active",
                              completion: completion),
            "SELECT * FROM users WHERE status = 'active'")
        XCTAssertEqual(sql.rewriteForRun("SELECT 1", completion: nil), "SELECT 1")
        XCTAssertEqual(redis.rewriteForRun("SET status active", completion: completion),
                       "SET status active")
    }

    func testExplainCapability() {
        XCTAssertTrue(sql.supportsExplain)
        XCTAssertFalse(redis.supportsExplain)
    }
}

final class QueryParametersTests: XCTestCase {

    func testNamesSkipLiteralsCommentsAndCasts() {
        let sql = """
        SELECT ':not_me', "a:b", x::int -- :nor_me
        FROM t WHERE a = :first AND b = :second AND c = :first
        """
        XCTAssertEqual(QueryParameters.names(in: sql), ["first", "second"])
    }

    func testSubstituteLiteralRules() {
        XCTAssertEqual(QueryParameters.literal(for: ""), "NULL")
        XCTAssertEqual(QueryParameters.literal(for: "null"), "NULL")
        XCTAssertEqual(QueryParameters.literal(for: "42.5"), "42.5")
        XCTAssertEqual(QueryParameters.literal(for: "-1e3"), "-1e3")
        XCTAssertEqual(QueryParameters.literal(for: "abc"), "'abc'")
        XCTAssertEqual(QueryParameters.literal(for: "it's"), "'it''s'")
        XCTAssertEqual(QueryParameters.literal(for: #"a\b"#, backslashEscapes: true),
                       #"'a\\b'"#)
    }

    func testMySQLBackslashInsideStringDoesNotEndLiteral() {
        let sql = #"SELECT 'it\'s fine' WHERE x = :param"#
        XCTAssertEqual(QueryParameters.names(in: sql, backslashEscapes: true), ["param"])
    }
}
