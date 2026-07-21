import XCTest
@testable import DBKit

final class PlanParserTests: XCTestCase {

    private func jsonResult(_ text: String) -> QueryResult {
        QueryResult(columns: [ColumnDescriptor(name: "QUERY PLAN", typeName: "json")],
                    rows: [[Cell(text)]])
    }

    // MARK: PostgreSQL

    func testPostgresPlainPlanBuildsTreeWithCosts() {
        let plan = PlanParser.parse(result: jsonResult("""
        [{"Plan": {
            "Node Type": "Hash Join", "Join Type": "Left",
            "Total Cost": 100.5, "Plan Rows": 500, "Hash Cond": "(a.id = b.a_id)",
            "Plans": [
                {"Node Type": "Seq Scan", "Relation Name": "a",
                 "Total Cost": 20.0, "Plan Rows": 1000},
                {"Node Type": "Hash", "Total Cost": 60.0, "Plan Rows": 500,
                 "Plans": [
                    {"Node Type": "Index Scan", "Relation Name": "b",
                     "Index Name": "b_pkey", "Total Cost": 40.0, "Plan Rows": 500,
                     "Index Cond": "(a_id > 3)"}
                 ]}
            ]}}]
        """), format: .json, engine: .postgres)

        let root = try! XCTUnwrap(plan).root
        XCTAssertEqual(root.label, "Hash Join (Left)")
        XCTAssertEqual(root.estimatedCost, 100.5)
        XCTAssertEqual(root.detail, "Hash Cond: (a.id = b.a_id)")
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(root.children[0].relation, "a")
        let indexScan = root.children[1].children[0]
        XCTAssertEqual(indexScan.relation, "b · b_pkey")
        XCTAssertEqual(indexScan.detail, "Index Cond: (a_id > 3)")
        XCTAssertFalse(plan!.isAnalyzed)
        // Depth-first ids: root 0, seq scan 1, hash 2, index scan 3.
        XCTAssertEqual([root.id, root.children[0].id, root.children[1].id, indexScan.id],
                       [0, 1, 2, 3])
    }

    func testPostgresAnalyzePlanDerivesSelfTimeShareAndWarnings() {
        let plan = PlanParser.parse(result: jsonResult("""
        [{"Plan": {
            "Node Type": "Nested Loop", "Plan Rows": 10,
            "Actual Rows": 2000, "Actual Loops": 1, "Actual Total Time": 100.0,
            "Plans": [
                {"Node Type": "Seq Scan", "Relation Name": "big",
                 "Plan Rows": 50000, "Actual Rows": 50000, "Actual Loops": 1,
                 "Actual Total Time": 80.0},
                {"Node Type": "Index Scan", "Relation Name": "small",
                 "Plan Rows": 1, "Actual Rows": 1, "Actual Loops": 2000,
                 "Actual Total Time": 0.005}
            ]},
          "Planning Time": 0.2, "Execution Time": 101.0}]
        """), format: .json, engine: .postgres)

        let unwrapped = try! XCTUnwrap(plan)
        XCTAssertTrue(unwrapped.isAnalyzed)
        XCTAssertEqual(unwrapped.planningTimeMS, 0.2)
        XCTAssertEqual(unwrapped.executionTimeMS, 101.0)

        let root = unwrapped.root
        // Root inclusive 100, children inclusive 80 + 0.005×2000 = 90 → self 10.
        XCTAssertEqual(root.selfTimeMS!, 10.0, accuracy: 0.001)
        XCTAssertEqual(root.shareOfTotal!, 0.1, accuracy: 0.001)
        // 10 estimated vs 2000 actual → misestimate ≥ 10×.
        XCTAssertTrue(root.warnings.contains { if case .rowsMisestimate = $0 { true } else { false } })
        // Seq scan over 50k rows.
        XCTAssertTrue(root.children[0].warnings.contains(.sequentialScan))
        XCTAssertEqual(root.children[0].shareOfTotal!, 0.8, accuracy: 0.001)
        // Loops multiply actuals: 1 row × 2000 loops.
        XCTAssertEqual(root.children[1].actualRows, 2000)
    }

    func testGatherWorkersDoNotSumPastWallClock() {
        // Parallel loops run concurrently: the child's per-worker average must
        // not be multiplied into summed CPU time exceeding the whole query.
        let plan = PlanParser.parse(result: jsonResult("""
        [{"Plan": {
            "Node Type": "Gather", "Actual Rows": 90000, "Actual Loops": 1,
            "Actual Total Time": 120.0, "Plan Rows": 90000,
            "Plans": [
                {"Node Type": "Parallel Seq Scan", "Relation Name": "big",
                 "Plan Rows": 30000, "Actual Rows": 30000, "Actual Loops": 3,
                 "Actual Total Time": 100.0}
            ]},
          "Execution Time": 125.0}]
        """), format: .json, engine: .postgres)

        let root = try! XCTUnwrap(plan).root
        let scan = root.children[0]
        XCTAssertEqual(scan.actualTotalTimeMS, 100.0)   // per-worker, not ×3
        XCTAssertEqual(scan.actualRows, 90000)          // rows are disjoint → ×3
        XCTAssertEqual(root.selfTimeMS!, 20.0, accuracy: 0.001)
    }

    func testInitPlanChildIsNotSubtractedTwice() {
        // The CTE fill time reappears inside the consuming scan; subtracting
        // the InitPlan child too would clamp the parent's self time to zero.
        let plan = PlanParser.parse(result: jsonResult("""
        [{"Plan": {
            "Node Type": "Hash Join", "Actual Rows": 10, "Actual Loops": 1,
            "Actual Total Time": 90.0, "Plan Rows": 10,
            "Plans": [
                {"Node Type": "CTE Scan", "Parent Relationship": "InitPlan",
                 "Actual Rows": 100, "Actual Loops": 1, "Actual Total Time": 80.0,
                 "Plan Rows": 100},
                {"Node Type": "Seq Scan", "Relation Name": "t",
                 "Actual Rows": 100, "Actual Loops": 1, "Actual Total Time": 85.0,
                 "Plan Rows": 100}
            ]}}]
        """), format: .json, engine: .postgres)

        let root = try! XCTUnwrap(plan).root
        XCTAssertEqual(root.selfTimeMS!, 5.0, accuracy: 0.001)
        XCTAssertEqual(root.children[0].parentRelationship, "InitPlan")
    }

    func testSQLiteCorruptDuplicateIDsDoNotRecurseForever() {
        let result = QueryResult(
            columns: ["id", "parent", "notused", "detail"].map {
                ColumnDescriptor(name: $0, typeName: "int")
            },
            rows: [
                [Cell("1"), Cell("0"), Cell("0"), Cell("SCAN a")],
                [Cell("2"), Cell("1"), Cell("0"), Cell("SCAN b")],
                [Cell("1"), Cell("2"), Cell("0"), Cell("SCAN c")],
            ],
            isTruncated: false)
        // Must terminate (visited guard), whatever tree it settles on.
        _ = PlanParser.parse(result: result, format: .sqliteQueryPlan, engine: .sqlite)
    }

    func testPostgresSortSpillWarning() {
        let plan = PlanParser.parse(result: jsonResult("""
        [{"Plan": {"Node Type": "Sort", "Sort Method": "external merge",
                   "Sort Space Type": "Disk", "Plan Rows": 5}}]
        """), format: .json, engine: .postgres)
        XCTAssertEqual(try! XCTUnwrap(plan).root.warnings.filter { $0 == .spilledToDisk }.count, 2)
    }

    // MARK: MySQL / MariaDB

    func testMySQLNestedLoopPlan() {
        let plan = PlanParser.parse(result: jsonResult("""
        {"query_block": {
            "select_id": 1,
            "cost_info": {"query_cost": "180.50"},
            "nested_loop": [
                {"table": {"table_name": "orders", "access_type": "ALL",
                           "rows_examined_per_scan": 50000,
                           "cost_info": {"read_cost": "120.00"}}},
                {"table": {"table_name": "users", "access_type": "eq_ref",
                           "key": "PRIMARY", "rows_examined_per_scan": 1,
                           "attached_condition": "(users.active = 1)"}}
            ]}}
        """), format: .json, engine: .mysql)

        let root = try! XCTUnwrap(plan).root
        XCTAssertEqual(root.label, "Query Block")
        XCTAssertEqual(root.estimatedCost, 180.5)
        XCTAssertEqual(root.children.count, 1)
        let loop = root.children[0]
        XCTAssertEqual(loop.label, "Nested Loop")
        XCTAssertEqual(loop.children.map(\.label), ["orders (ALL)", "users (eq_ref)"])
        XCTAssertTrue(loop.children[0].warnings.contains(.sequentialScan))
        XCTAssertEqual(loop.children[1].relation, "PRIMARY")
        XCTAssertEqual(loop.children[1].detail, "(users.active = 1)")
        XCTAssertFalse(plan!.isAnalyzed)
    }

    func testMariaDBAnalyzePlanCarriesActuals() {
        let plan = PlanParser.parse(result: jsonResult("""
        {"query_block": {
            "select_id": 1, "r_total_time_ms": 42.5,
            "table": {"table_name": "events", "access_type": "ALL",
                      "rows": 1200, "r_rows": 15000, "r_total_time_ms": 40.0}}}
        """), format: .json, engine: .mariadb)

        let unwrapped = try! XCTUnwrap(plan)
        XCTAssertTrue(unwrapped.isAnalyzed)
        let table = unwrapped.root.children[0]
        XCTAssertEqual(table.actualRows, 15000)
        XCTAssertEqual(table.actualTotalTimeMS, 40.0)
        XCTAssertTrue(table.warnings.contains(.sequentialScan))
        // 1200 est vs 15000 actual → ≥10× misestimate.
        XCTAssertTrue(table.warnings.contains { if case .rowsMisestimate = $0 { true } else { false } })
    }

    func testMySQLPlanWithoutTablesFallsBack() {
        let plan = PlanParser.parse(result: jsonResult("""
        {"query_block": {"select_id": 1, "message": "No tables used"}}
        """), format: .json, engine: .mysql)
        XCTAssertNil(plan)
    }

    // MARK: SQLite

    func testSQLiteQueryPlanRowsAssembleIntoTree() {
        let result = QueryResult(
            columns: ["id", "parent", "notused", "detail"].map {
                ColumnDescriptor(name: $0, typeName: "int")
            },
            rows: [
                [Cell("3"), Cell("0"), Cell("0"), Cell("SCAN orders")],
                [Cell("8"), Cell("3"), Cell("0"),
                 Cell("SEARCH users USING INDEX sqlite_autoindex_users_1 (id=?)")],
                [Cell("20"), Cell("0"), Cell("0"), Cell("USE TEMP B-TREE FOR ORDER BY")],
            ],
            isTruncated: false)

        let plan = PlanParser.parse(result: result, format: .sqliteQueryPlan, engine: .sqlite)
        let root = try! XCTUnwrap(plan).root
        // Two top-level rows → synthetic root.
        XCTAssertEqual(root.label, "Query Plan")
        XCTAssertEqual(root.children.map(\.label), ["SCAN orders", "USE TEMP B-TREE FOR ORDER BY"])
        XCTAssertTrue(root.children[0].warnings.contains(.sequentialScan))
        let search = root.children[0].children[0]
        XCTAssertTrue(search.label.hasPrefix("SEARCH users"))
        XCTAssertTrue(search.warnings.isEmpty)
        XCTAssertFalse(plan!.isAnalyzed)
    }

    // MARK: Failure modes

    func testGarbageAndEmptyInputsReturnNil() {
        XCTAssertNil(PlanParser.parse(result: jsonResult("not json"),
                                      format: .json, engine: .postgres))
        XCTAssertNil(PlanParser.parse(result: jsonResult("{}"),
                                      format: .json, engine: .postgres))
        XCTAssertNil(PlanParser.parse(result: jsonResult("[]"),
                                      format: .json, engine: .postgres))
        XCTAssertNil(PlanParser.parse(result: jsonResult("{}"),
                                      format: .json, engine: .mysql))
        XCTAssertNil(PlanParser.parse(result: QueryResult(),
                                      format: .json, engine: .postgres))
        XCTAssertNil(PlanParser.parse(result: QueryResult(),
                                      format: .sqliteQueryPlan, engine: .sqlite))
    }

    func testOversizedPayloadReturnsNil() {
        let huge = "[" + String(repeating: " ", count: PlanParser.maxPayloadBytes) + "]"
        XCTAssertNil(PlanParser.parse(result: jsonResult(huge),
                                      format: .json, engine: .postgres))
    }

    func testParsingIsDeterministic() {
        let text = """
        [{"Plan": {"Node Type": "Sort", "Custom A": 1, "Custom B": "x", "Zeta": true,
                   "Plans": [{"Node Type": "Seq Scan", "Relation Name": "t"}]}}]
        """
        let first = PlanParser.parse(result: jsonResult(text), format: .json, engine: .postgres)
        let second = PlanParser.parse(result: jsonResult(text), format: .json, engine: .postgres)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.root.extra.map(\.key), ["Custom A", "Custom B", "Zeta"])
    }
}
