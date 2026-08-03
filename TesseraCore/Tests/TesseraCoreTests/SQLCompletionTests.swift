import XCTest
@testable import DBKit

/// Unit tests for the pure `SQLCompletionEngine` — the schema-aware SQL completion
/// logic, exercised entirely through its public API (no editor, no AppKit).
final class SQLCompletionTests: XCTestCase {

    // MARK: Fixture schema

    /// A small Postgres-shaped schema with foreign keys, so the FK-driven features
    /// (smart JOIN, ON, USING, key badges) have something to work with.
    private func makeEngine() -> SQLCompletionEngine {
        func col(_ name: String, _ type: String, pk: Bool = false, nn: Bool = false,
                 ref: ForeignKeyTarget? = nil) -> SchemaColumn {
            SchemaColumn(name: name, dataType: type, isPrimaryKey: pk,
                         isForeignKey: ref != nil, isNullable: !nn, references: ref)
        }
        let customers = SchemaTable(name: "customers", columns: [
            col("id", "int8", pk: true, nn: true),
            col("name", "text"),
            col("email", "text"),
        ], approximateRowCount: 12_000)
        let orders = SchemaTable(name: "orders", columns: [
            col("id", "int8", pk: true, nn: true),
            col("customer_id", "int8", nn: true,
                ref: ForeignKeyTarget(schema: "public", table: "customers", column: "id")),
            col("status", "text"),
        ])
        let logs = SchemaTable(name: "logs", columns: [
            col("id", "int8", pk: true),
            col("order_id", "int8"),
        ])
        // Same-named key on both sides → USING is offered.
        let teams = SchemaTable(name: "teams", columns: [col("team_id", "int8", pk: true)])
        let memberships = SchemaTable(name: "memberships", columns: [
            col("id", "int8", pk: true),
            col("team_id", "int8",
                ref: ForeignKeyTarget(schema: "public", table: "teams", column: "team_id")),
        ])
        // Aliased-qualifier rewrite fixtures.
        let object = SchemaTable(name: "object", columns: [col("id", "int8", pk: true)])
        let action = SchemaTable(name: "action", columns: [
            col("id", "int8", pk: true),
            col("name", "text"),
            col("object_id", "int8",
                ref: ForeignKeyTarget(schema: "public", table: "object", column: "id")),
        ])
        let tree = DatabaseTree(databaseName: "shop", schemas: [
            SchemaNamespace(name: "public",
                            tables: [customers, orders, logs, teams, memberships, object, action]),
        ])
        return SQLCompletionEngine(schema: tree, engine: .postgres)
    }

    private func complete(_ text: String, caret: Int? = nil, forced: Bool = false)
        -> (range: NSRange, items: [SQLCompletionItem]) {
        makeEngine().complete(text: text, caret: caret ?? (text as NSString).length, forced: forced)
    }

    // MARK: Fuzzy matching

    func testFuzzyMatchFindsUnderscoredColumn() {
        // `oid` is not a prefix or substring of `order_id`, only a subsequence.
        let items = complete("SELECT oid FROM logs", caret: 10).items
        XCTAssertTrue(items.contains { $0.label == "order_id" },
                      "fuzzy `oid` should surface `order_id`")
    }

    // MARK: Column badges

    func testColumnBadgesPKAndForeignKeyAndNotNull() {
        let items = complete("SELECT * FROM orders o WHERE o.").items
        let id = items.first { $0.label == "id" }
        let fk = items.first { $0.label == "customer_id" }
        XCTAssertEqual(id?.detail, "int8 · PK · NOT NULL")
        XCTAssertEqual(fk?.detail, "int8 · FK→customers · NOT NULL")
    }

    func testTableDetailShowsRowCount() {
        let items = complete("SELECT * FROM ", forced: true).items
        let customers = items.first { $0.label == "customers" && $0.kind == .table }
        XCTAssertEqual(customers?.detail, "public · ~12k rows")
    }

    // MARK: Smart JOIN

    func testSmartJoinInsertsFullOnClause() {
        let items = complete("SELECT * FROM customers c JOIN ", forced: true).items
        let orders = items.first { $0.label == "orders" && $0.kind == .join }
        XCTAssertEqual(orders?.insert, "orders o ON o.customer_id = c.id")
        XCTAssertEqual(orders?.renameQualifier, .init(from: "orders", to: "o"))
    }

    func testSmartJoinUnrelatedTableJustAliases() {
        // `logs` has no FK link to customers → table + generated alias, no ON.
        let items = complete("SELECT * FROM customers c JOIN ", forced: true).items
        let logs = items.first { $0.label == "logs" }
        XCTAssertEqual(logs?.insert, "logs l")
    }

    func testJoinOffersUsingForSameNamedKey() {
        let items = complete("SELECT * FROM teams t JOIN ", forced: true).items
        XCTAssertTrue(items.contains { $0.insert == "memberships m USING (team_id)" },
                      "same-named join key should offer a USING variant")
    }

    func testOnPositionOffersForeignKeyEquality() {
        let items = complete("SELECT * FROM customers c JOIN orders o ON ", forced: true).items
        XCTAssertTrue(items.contains { $0.insert == "o.customer_id = c.id" && $0.kind == .join })
    }

    // MARK: Aliased-qualifier rewrite (`object.` → `o.`)

    func testQualifiedReferenceToAliasedTableRewritesToAlias() {
        // `object` is aliased `o`, so completing `object.` inserts `o.id` and the
        // replace range swallows the `object.` qualifier.
        let text = "select object. from object o"
        let result = complete(text, caret: 14)   // right after the first `object.`
        XCTAssertEqual(result.range, NSRange(location: 7, length: 7))   // covers "object."
        XCTAssertTrue(result.items.contains { $0.insert == "o.id" })
    }

    // MARK: CTE awareness

    func testCTENameIsOffered() {
        let items = complete("WITH recent AS (SELECT 1) SELECT * FROM re").items
        XCTAssertTrue(items.contains { $0.label == "recent" })
    }

    // MARK: SELECT * expansion

    func testSelectStarExpandsToColumnList() {
        let items = complete("SELECT  FROM customers", caret: 7, forced: true).items
        let all = items.first { $0.label == "∗ all columns" }
        XCTAssertEqual(all?.insert, "id, name, email")
    }

    // MARK: Keyword casing & function parens

    func testKeywordFollowsTypedLowercase() {
        let items = complete("sel").items
        let select = items.first { $0.label == "SELECT" }
        XCTAssertEqual(select?.insert, "select")
    }

    func testFunctionAutoClosesWithCaretInside() {
        let items = complete("cou").items
        let count = items.first { $0.label == "COUNT(" }
        XCTAssertEqual(count?.insert, "count()")
        XCTAssertEqual(count?.caretOffset, 1)   // caret between the parentheses
    }

    // MARK: Live alias rewrite

    func testPendingAliasRewriteWhenTableGetsAlias() {
        let text = "select action.name from action a "   // trailing space: alias is complete
        let renames = makeEngine().pendingAliasRewrites(text: text, caret: (text as NSString).length)
        XCTAssertEqual(renames, [.init(from: "action", to: "a")])
    }

    func testRenameRewritesQualifierAcrossStatement() {
        let text = "select action.name, action.id from action a "
        let result = makeEngine().rename(text: text, from: "action", to: "a",
                                         caret: (text as NSString).length,
                                         excluding: NSRange(location: 0, length: 0))
        XCTAssertEqual(result?.text, "select a.name, a.id from action a ")
    }

    func testRenameLeavesUnrelatedText() {
        // No `orders.` qualifier present → nothing to do.
        let text = "select action.name from action a "
        let result = makeEngine().rename(text: text, from: "orders", to: "o",
                                         caret: (text as NSString).length,
                                         excluding: NSRange(location: 0, length: 0))
        XCTAssertNil(result)
    }
}
