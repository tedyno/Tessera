import XCTest
@testable import DBKit

/// Unit tests for the pure edit/data-view SQL generation — the code that writes to
/// the user's database, exercised without any live connection.
final class RowEditSQLTests: XCTestCase {

    private let pg: any SQLDialect = DatabaseKind.postgres.dialect

    private func result(_ columns: [(String, String)], _ rows: [[String?]]) -> QueryResult {
        QueryResult(columns: columns.map { ColumnDescriptor(name: $0.0, typeName: $0.1) },
                    rows: rows.map { $0.map { Cell($0) } })
    }

    private func usersResult() -> QueryResult {
        result([("id", "INTEGER"), ("name", "text"), ("active", "boolean")],
               [["1", "Alice", "true"], ["2", "Bob", "false"]])
    }

    private let users = EditSource(schema: "public", table: "users",
                                   primaryKeys: ["id"], autoIncrementColumns: ["id"])

    // MARK: Statement generation

    func testUpdateQuotingAcrossDialects() {
        // The same edit must come out with each engine's own identifier quoting —
        // these statements run against the user's database on commit.
        let edits: [Int: [String: String?]] = [0: ["name": "O'Brien"]]
        let cases: [(DatabaseKind, String)] = [
            (.postgres, #"UPDATE "public"."users" SET "name" = 'O''Brien' WHERE "id" IN (1);"#),
            (.mysql, "UPDATE `public`.`users` SET `name` = 'O''Brien' WHERE `id` IN (1);"),
            (.sqlite, #"UPDATE "public"."users" SET "name" = 'O''Brien' WHERE "id" IN (1);"#),
        ]
        for (kind, expected) in cases {
            let stmts = RowEditSQL.statements(source: users, result: usersResult(),
                                              edits: edits, deletes: [], inserts: [],
                                              dialect: kind.dialect)
            XCTAssertEqual(stmts, [expected], "\(kind) dialect")
        }
    }

    func testUpdateUsesInClauseAndEscapes() {
        let stmts = RowEditSQL.statements(source: users, result: usersResult(),
                                          edits: [0: ["name": "O'Brien"]], deletes: [], inserts: [],
                                          dialect: pg)
        XCTAssertEqual(stmts, [#"UPDATE "public"."users" SET "name" = 'O''Brien' WHERE "id" IN (1);"#])
    }

    func testNumericColumnValueIsUnquoted() {
        let stmts = RowEditSQL.statements(source: users, result: usersResult(),
                                          edits: [1: ["id": "99"]], deletes: [], inserts: [], dialect: pg)
        // id is numeric → RHS unquoted; the IN key is the (numeric) old id, also unquoted.
        XCTAssertEqual(stmts, [#"UPDATE "public"."users" SET "id" = 99 WHERE "id" IN (2);"#])
    }

    func testSetToNullEmitsNULL() {
        let stmts = RowEditSQL.statements(source: users, result: usersResult(),
                                          edits: [0: ["name": nil]], deletes: [], inserts: [], dialect: pg)
        XCTAssertEqual(stmts, [#"UPDATE "public"."users" SET "name" = NULL WHERE "id" IN (1);"#])
    }

    func testDeleteInsertAndUpdateOrderAndCollapse() {
        let stmts = RowEditSQL.statements(
            source: users, result: usersResult(),
            edits: [0: ["active": "false"]], deletes: [1], inserts: [["name": "Carol"]], dialect: pg)
        XCTAssertEqual(stmts, [
            #"DELETE FROM "public"."users" WHERE "id" IN (2);"#,
            #"UPDATE "public"."users" SET "active" = 'false' WHERE "id" IN (1);"#,
            // id is auto-increment → omitted; active never set → omitted.
            #"INSERT INTO "public"."users" ("name") VALUES ('Carol');"#,
        ])
    }

    func testIdenticalEditsCollapseIntoOneUpdate() {
        let stmts = RowEditSQL.statements(
            source: users, result: usersResult(),
            edits: [0: ["active": "false"], 1: ["active": "false"]], deletes: [], inserts: [], dialect: pg)
        XCTAssertEqual(stmts, [#"UPDATE "public"."users" SET "active" = 'false' WHERE "id" IN (1, 2);"#])
    }

    func testKeylessTableMatchesAllColumns() {
        let source = EditSource(schema: "public", table: "logs", primaryKeys: [], autoIncrementColumns: [])
        let res = result([("a", "INTEGER"), ("b", "text")], [["1", "x"]])
        let stmts = RowEditSQL.statements(source: source, result: res,
                                          edits: [0: ["b": "y"]], deletes: [], inserts: [], dialect: pg)
        XCTAssertEqual(stmts, [#"UPDATE "public"."logs" SET "b" = 'y' WHERE "a" = 1 AND "b" = 'x';"#])
    }

    // MARK: Cell edit tracking

    func testEditRecordsNewValue() {
        let edits = RowEditSQL.applyingEdit(to: nil, column: "name", newValue: "Bob", original: "Alice")
        XCTAssertEqual(edits?["name"], "Bob")
    }

    func testEditBackToOriginalDropsTheEdit() {
        // A row already edited, then set back to the fetched original → no edits left.
        let edits = RowEditSQL.applyingEdit(to: ["name": "Bob"], column: "name",
                                            newValue: "Alice", original: "Alice")
        XCTAssertNil(edits)
    }

    func testSetToNullIsRecordedDistinctFromDrop() {
        // Setting a non-null cell to NULL is a real edit (key present, value nil).
        let edits = RowEditSQL.applyingEdit(to: nil, column: "name", newValue: nil, original: "Alice")
        XCTAssertNotNil(edits)
        XCTAssertTrue(edits!.keys.contains("name"))
        XCTAssertEqual(edits!["name"], .some(nil))
    }

    func testSettingAlreadyNullCellIsANoOp() {
        let edits = RowEditSQL.applyingEdit(to: nil, column: "name", newValue: nil, original: nil)
        XCTAssertNil(edits)
    }

    // MARK: Editable-source detection

    private func schema() -> DatabaseTree {
        DatabaseTree(databaseName: "shop", schemas: [SchemaNamespace(name: "public", tables: [
            SchemaTable(name: "users", columns: [
                SchemaColumn(name: "id", dataType: "int8", isPrimaryKey: true, isAutoIncrement: true),
                SchemaColumn(name: "name", dataType: "text"),
            ]),
            SchemaTable(name: "events", columns: [SchemaColumn(name: "payload", dataType: "text")]),
        ])])
    }

    private let cols = [ColumnDescriptor(name: "id", typeName: "int8"),
                        ColumnDescriptor(name: "name", typeName: "text")]

    func testDetectEditableSelectStar() {
        let src = RowEditSQL.detectEditSource(sql: "SELECT * FROM users", columns: cols, schema: schema())
        XCTAssertEqual(src, EditSource(schema: "public", table: "users",
                                       primaryKeys: ["id"], autoIncrementColumns: ["id"]))
    }

    func testDetectRejectsJoinAndProjection() {
        XCTAssertNil(RowEditSQL.detectEditSource(sql: "SELECT * FROM users JOIN a ON a.id = users.id",
                                                 columns: cols, schema: schema()))
        XCTAssertNil(RowEditSQL.detectEditSource(sql: "SELECT id, name FROM users",
                                                 columns: cols, schema: schema()))
    }

    func testDetectRejectsWhenPrimaryKeyMissingFromResult() {
        let noID = [ColumnDescriptor(name: "name", typeName: "text")]
        XCTAssertNil(RowEditSQL.detectEditSource(sql: "SELECT * FROM users", columns: noID, schema: schema()))
    }

    // MARK: Projected-column recovery (zero-row headers)

    private func projNames(_ sql: String) -> [String]? {
        RowEditSQL.projectedColumns(sql: sql, schema: schema())?.map(\.name)
    }
    private func projCols(_ sql: String) -> [ColumnDescriptor]? {
        RowEditSQL.projectedColumns(sql: sql, schema: schema())
    }

    func testProjectionStarSingleTable() {
        XCTAssertEqual(projNames("SELECT * FROM users"), ["id", "name"])
        // A zero-row filter or ordering doesn't change the shape.
        XCTAssertEqual(projNames("SELECT * FROM users WHERE 1 = 0 ORDER BY id LIMIT 5"), ["id", "name"])
        XCTAssertEqual(projNames("SELECT * FROM public.users"), ["id", "name"])
        // Star carries the schema's types.
        XCTAssertEqual(projCols("SELECT * FROM users")?.map(\.typeName), ["int8", "text"])
        XCTAssertEqual(projCols("SELECT u.* FROM users u")?.map(\.name), ["id", "name"])
    }

    func testProjectionStarAcrossJoinConcatenatesInFromOrder() {
        XCTAssertEqual(projNames("SELECT * FROM users u JOIN events e ON e.id = u.id"),
                       ["id", "name", "payload"])
        XCTAssertEqual(projNames("SELECT * FROM users, events"), ["id", "name", "payload"])
        XCTAssertEqual(projNames("SELECT * FROM events LEFT OUTER JOIN users ON true"),
                       ["payload", "id", "name"])
    }

    func testProjectionExplicitListNamesAndTypes() {
        // Plain columns keep their names; a known column gets its schema type, an
        // unknown one a blank type.
        let cols = projCols("SELECT id, name, missing FROM users")
        XCTAssertEqual(cols?.map(\.name), ["id", "name", "missing"])
        XCTAssertEqual(cols?.map(\.typeName), ["int8", "text", ""])
        XCTAssertEqual(projNames("SELECT u.id, u.name FROM users u"), ["id", "name"])
    }

    func testProjectionAliasesAndExpressions() {
        XCTAssertEqual(projNames("SELECT id AS pk, name n FROM users"), ["pk", "n"])
        // Expressions with no alias are named by their (whitespace-collapsed) text;
        // commas inside a function call don't split the list.
        XCTAssertEqual(projNames("SELECT count(*), coalesce(name, id) FROM users"),
                       ["count(*)", "coalesce(name, id)"])
        XCTAssertEqual(projNames("SELECT price * 2 AS total FROM users"), ["total"])
        // A trailing operand is not mistaken for an alias.
        XCTAssertEqual(projNames("SELECT a + b FROM users"), ["a + b"])
        // Alias with a blank type when the underlying value is an expression.
        XCTAssertEqual(projCols("SELECT count(*) AS n FROM users")?.map(\.typeName), [""])
    }

    func testProjectionJoinFormsFromReviewFindings() {
        // STRAIGHT_JOIN is the join keyword itself, not a modifier — its table counts.
        XCTAssertEqual(projNames("SELECT * FROM users straight_join events"),
                       ["id", "name", "payload"])
        // Schema-qualified star.
        XCTAssertEqual(projNames("SELECT public.users.* FROM public.users"), ["id", "name"])
        // A parenthesised ON / USING condition is not mistaken for a subquery.
        XCTAssertEqual(projNames("SELECT * FROM users u JOIN events e ON lower(u.name) = e.payload"),
                       ["id", "name", "payload"])
        XCTAssertEqual(projNames("SELECT * FROM users JOIN events USING (id)"),
                       ["id", "name", "payload"])
        // Trailing alias after a CASE expression.
        XCTAssertEqual(projNames("SELECT CASE WHEN id > 0 THEN 1 ELSE 0 END status FROM users"),
                       ["status"])
    }

    func testProjectionReturnsNilWhenStarUnresolvable() {
        XCTAssertNil(projNames("SELECT * FROM (SELECT 1) x"))   // subquery in FROM
        XCTAssertNil(projNames("SELECT * FROM missing"))        // unknown table
        XCTAssertNil(projNames("UPDATE users SET name = 'x'"))  // not a SELECT
        // An explicit list still works even when FROM is a subquery (names only).
        XCTAssertEqual(projNames("SELECT id, name FROM (SELECT * FROM users) x"), ["id", "name"])
    }

    func testDetectKeylessTableFallsBack() {
        let src = RowEditSQL.detectEditSource(sql: "SELECT * FROM events",
                                              columns: [ColumnDescriptor(name: "payload", typeName: "text")],
                                              schema: schema())
        XCTAssertEqual(src?.primaryKeys, [])
        XCTAssertEqual(src?.table, "events")
    }

    // MARK: Data-view SQL

    func testDataViewSelectFoldsFilterSortLimit() {
        let sql = DataViewSQL.select(
            schema: "public", table: "users", filter: "active = true",
            sortOrder: [.init(column: "id", ascending: true)],
            limit: 100, offset: 200, orderOverride: nil, unlimited: false, dialect: pg)
        XCTAssertEqual(sql, #"SELECT * FROM "public"."users" WHERE active = true ORDER BY "id" ASC LIMIT 100 OFFSET 200"#)
    }

    func testDataViewUnlimitedDropsPaging() {
        let sql = DataViewSQL.select(schema: "public", table: "users", filter: "",
                                     sortOrder: [], limit: 100, offset: nil, orderOverride: nil,
                                     unlimited: true, dialect: pg)
        XCTAssertEqual(sql, #"SELECT * FROM "public"."users""#)
    }

    func testRewriteOrderByReplacesExisting() {
        let sql = DataViewSQL.rewriteOrderBy("SELECT * FROM t ORDER BY x LIMIT 10",
                                             sortOrder: [.init(column: "id", ascending: false)], dialect: pg)
        XCTAssertEqual(sql, #"SELECT * FROM t ORDER BY "id" DESC LIMIT 10"#)
    }

    func testRewriteOrderByRemovesWhenEmpty() {
        let sql = DataViewSQL.rewriteOrderBy("SELECT * FROM t ORDER BY x", sortOrder: [], dialect: pg)
        XCTAssertEqual(sql, "SELECT * FROM t")
    }

    func testRewriteOrderByIgnoresKeywordInsideStringLiteral() {
        // `limit` inside the literal must not be treated as a LIMIT clause.
        let sql = DataViewSQL.rewriteOrderBy("SELECT * FROM t WHERE note = 'a limit b'",
                                             sortOrder: [.init(column: "id", ascending: true)], dialect: pg)
        XCTAssertEqual(sql, #"SELECT * FROM t WHERE note = 'a limit b' ORDER BY "id" ASC"#)
    }
}
