import XCTest
@testable import DBKit

final class SQLAutoQuoteTests: XCTestCase {

    /// users(id int, name text, email text, status text, note text,
    ///       created_at timestamp, zip text)
    private var scope: SQLAutoQuote.Scope {
        SQLAutoQuote.Scope(table: SchemaTable(name: "users", columns: [
            SchemaColumn(name: "id", dataType: "integer", isPrimaryKey: true),
            SchemaColumn(name: "name", dataType: "text"),
            SchemaColumn(name: "email", dataType: "text"),
            SchemaColumn(name: "status", dataType: "text"),
            SchemaColumn(name: "note", dataType: "text"),
            SchemaColumn(name: "created_at", dataType: "timestamp"),
            SchemaColumn(name: "zip", dataType: "text"),
        ]))
    }

    private func quoted(_ sql: String) -> String {
        SQLAutoQuote.quoted(sql, scope: scope)
    }

    // MARK: Quoting

    func testQuotesBareWord() {
        XCTAssertEqual(quoted("name = John"), "name = 'John'")
    }

    func testQuotesEmailishValue() {
        XCTAssertEqual(quoted("email = foo@bar.com"), "email = 'foo@bar.com'")
    }

    func testQuotesMultiWordValueUpToBoundary() {
        XCTAssertEqual(quoted("name = John Doe AND id = 5"),
                       "name = 'John Doe' AND id = 5")
    }

    func testQuotesLikePattern() {
        XCTAssertEqual(quoted("name LIKE %jo%"), "name LIKE '%jo%'")
        XCTAssertEqual(quoted("name NOT ILIKE %jo%"), "name NOT ILIKE '%jo%'")
    }

    func testQuotesDateAgainstTimestampColumn() {
        XCTAssertEqual(quoted("created_at >= 2026-01-01"),
                       "created_at >= '2026-01-01'")
        XCTAssertEqual(quoted("created_at >= 2026-01-01 10:30:00"),
                       "created_at >= '2026-01-01 10:30:00'")
    }

    func testQuotesInListElements() {
        XCTAssertEqual(quoted("status IN (open, closed)"),
                       "status IN ('open', 'closed')")
        XCTAssertEqual(quoted("status IN ('open', closed)"),
                       "status IN ('open', 'closed')")
        XCTAssertEqual(quoted("status NOT IN (open)"), "status NOT IN ('open')")
    }

    func testQuotesBetweenBounds() {
        XCTAssertEqual(quoted("created_at BETWEEN 2026-01-01 AND 2026-02-01"),
                       "created_at BETWEEN '2026-01-01' AND '2026-02-01'")
    }

    func testQuotesQualifiedColumn() {
        XCTAssertEqual(quoted("users.name = John"), "users.name = 'John'")
        XCTAssertEqual(quoted("\"users\".\"name\" = John"), "\"users\".\"name\" = 'John'")
    }

    func testConvertsMisquotedDoubleQuotedString() {
        XCTAssertEqual(quoted("name = \"John\""), "name = 'John'")
    }

    func testEscapesEmbeddedQuote() {
        XCTAssertEqual(quoted("name = O'Brien AND id = 1"), "name = O'Brien AND id = 1",
                       "a span containing a quote is left alone — part is already a literal")
        XCTAssertEqual(quoted("name = John\u{2019}s"), "name = 'John\u{2019}s'")
    }

    // MARK: Left alone

    func testLeavesNumericColumnAlone() {
        XCTAssertEqual(quoted("id = 42"), "id = 42")
        XCTAssertEqual(quoted("id = abc"), "id = abc")
    }

    func testLeavesPlainNumberAlone() {
        // Conservative: a numeric literal against a text column may be intended.
        XCTAssertEqual(quoted("zip = 12345"), "zip = 12345")
    }

    func testLeavesQuotedValueAlone() {
        XCTAssertEqual(quoted("name = 'John'"), "name = 'John'")
    }

    func testLeavesKeywordsAlone() {
        XCTAssertEqual(quoted("name IS NULL"), "name IS NULL")
        XCTAssertEqual(quoted("status = NULL"), "status = NULL")
        XCTAssertEqual(quoted("status = true"), "status = true")
        XCTAssertEqual(quoted("created_at >= CURRENT_DATE"), "created_at >= CURRENT_DATE")
        XCTAssertEqual(quoted("created_at >= INTERVAL '1 day'"),
                       "created_at >= INTERVAL '1 day'")
    }

    func testLeavesColumnComparisonAlone() {
        XCTAssertEqual(quoted("name = email"), "name = email")
        XCTAssertEqual(quoted("name = users.email"), "name = users.email")
    }

    func testLeavesFunctionCallAlone() {
        XCTAssertEqual(quoted("created_at >= NOW()"), "created_at >= NOW()")
        XCTAssertEqual(quoted("name = lower(email)"), "name = lower(email)")
    }

    func testLeavesParametersAlone() {
        XCTAssertEqual(quoted("name = $1"), "name = $1")
        XCTAssertEqual(quoted("name = :name"), "name = :name")
        XCTAssertEqual(quoted("name = ?"), "name = ?")
    }

    func testLeavesUnknownColumnAlone() {
        XCTAssertEqual(quoted("nickname = John"), "nickname = John")
    }

    func testLeavesSubqueryAlone() {
        XCTAssertEqual(quoted("status IN (SELECT status FROM archived)"),
                       "status IN (SELECT status FROM archived)")
        XCTAssertEqual(quoted("name = (SELECT max(name) FROM users)"),
                       "name = (SELECT max(name) FROM users)")
    }

    func testValueInsideExistingLiteralIsNotTouched() {
        XCTAssertEqual(quoted("note = 'a = b' AND name = John"),
                       "note = 'a = b' AND name = 'John'")
    }

    func testNonBMPLiteralKeepsLaterOffsetsAligned() {
        XCTAssertEqual(quoted("note = '😀😀' AND name = John"),
                       "note = '😀😀' AND name = 'John'")
    }

    func testDoubleQuotedColumnNameIsNotConverted() {
        XCTAssertEqual(quoted("name = \"email\""), "name = \"email\"")
    }

    // MARK: Full statements via the completion engine's scope

    private func statementScope(_ sql: String) -> SQLAutoQuote.Scope {
        let tree = DatabaseTree(databaseName: "app", schemas: [
            SchemaNamespace(name: "public", tables: [
                SchemaTable(name: "users", columns: [
                    SchemaColumn(name: "id", dataType: "integer", isPrimaryKey: true),
                    SchemaColumn(name: "name", dataType: "text"),
                ]),
                SchemaTable(name: "orders", columns: [
                    SchemaColumn(name: "user_id", dataType: "integer"),
                    SchemaColumn(name: "state", dataType: "text"),
                ]),
            ]),
        ])
        return SQLCompletionEngine(schema: tree, engine: .postgres).statementScope(sql)
    }

    func testStatementWhereIsQuoted() {
        let sql = "SELECT * FROM users WHERE name = John"
        XCTAssertEqual(SQLAutoQuote.quoted(sql, scope: statementScope(sql)),
                       "SELECT * FROM users WHERE name = 'John'")
    }

    func testStatementAliasedComparisonIsQuoted() {
        let sql = "SELECT * FROM users u JOIN orders o ON o.user_id = u.id WHERE o.state = open"
        XCTAssertEqual(SQLAutoQuote.quoted(sql, scope: statementScope(sql)),
                       "SELECT * FROM users u JOIN orders o ON o.user_id = u.id WHERE o.state = 'open'")
    }

    func testStatementJoinConditionIsNotTouched() {
        let sql = "SELECT * FROM users u JOIN orders o ON o.user_id = u.id"
        XCTAssertEqual(SQLAutoQuote.quoted(sql, scope: statementScope(sql)), sql)
    }

    func testStatementUpdateSetIsQuoted() {
        let sql = "UPDATE users SET name = John WHERE id = 3"
        XCTAssertEqual(SQLAutoQuote.quoted(sql, scope: statementScope(sql)),
                       "UPDATE users SET name = 'John' WHERE id = 3")
    }

    func testStatementOutsideScopeIsUntouched() {
        let sql = "SELECT * FROM unknown_table WHERE name = John"
        XCTAssertEqual(SQLAutoQuote.quoted(sql, scope: statementScope(sql)), sql)
    }
}
