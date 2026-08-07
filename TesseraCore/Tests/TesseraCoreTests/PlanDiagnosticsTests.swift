import XCTest
@testable import DBKit

final class PlanDiagnosticsTests: XCTestCase {

    private func treeResult(_ text: String) -> QueryResult {
        QueryResult(columns: [ColumnDescriptor(name: "EXPLAIN", typeName: "text")],
                    rows: [[Cell(text)]])
    }
    private func jsonResult(_ text: String) -> QueryResult {
        QueryResult(columns: [ColumnDescriptor(name: "QUERY PLAN", typeName: "json")],
                    rows: [[Cell(text)]])
    }

    // MARK: Operation classification

    func testOpKindClassification() {
        func op(_ label: String) -> PlanOpKind { .of(PlanNode(label: label)) }
        XCTAssertEqual(op("Seq Scan"), .fullScan)
        XCTAssertEqual(op("Table scan"), .fullScan)
        XCTAssertEqual(op("SCAN orders"), .fullScan)
        XCTAssertEqual(op("Index lookup"), .indexAccess)
        XCTAssertEqual(op("Index Only Scan"), .indexAccess)
        XCTAssertEqual(op("Nested loop inner join"), .join)
        XCTAssertEqual(op("Hash Join"), .join)
        XCTAssertEqual(op("Sort"), .sort)
        XCTAssertEqual(op("Group aggregate"), .aggregate)
        XCTAssertEqual(op("Filter"), .filter)
        XCTAssertEqual(op("Limit"), .limit)
        // Expanded coverage: compounds resolve before the plain word they contain.
        XCTAssertEqual(op("Hash"), .hashBuild)
        XCTAssertEqual(op("HashAggregate"), .aggregate)
        XCTAssertEqual(op("Bitmap Heap Scan"), .indexAccess)
        XCTAssertEqual(op("Gather Merge"), .gather)
        XCTAssertEqual(op("Materialize"), .materialize)
        XCTAssertEqual(op("Memoize"), .materialize)
        XCTAssertEqual(op("WindowAgg"), .window)
        XCTAssertEqual(op("Unique"), .distinct)
        XCTAssertEqual(op("Append"), .setOp)
        XCTAssertEqual(op("CTE Scan"), .subquery)
        XCTAssertEqual(op("Result"), .compute)
    }

    func testBottleneckCarriesLoopCount() {
        let tree =
            "-> Nested loop inner join  (cost=100 rows=10) (actual time=0.1..50.0 rows=8 loops=1)\n" +
            "    -> Table scan on big  (cost=50 rows=20000) (actual time=0.05..8.0 rows=20000 loops=1)\n" +
            "    -> Index lookup on small using pk (id = big.id)  (cost=5 rows=1) (actual time=0.001..0.002 rows=1 loops=20000)"
        let plan = PlanParser.parse(result: treeResult(tree), format: .mysqlTree, engine: .mysql)!

        let diag = PlanDiagnostics.diagnose(plan)
        let bottleneck = try! XCTUnwrap(diag.insights.first)
        guard case .bottleneck = bottleneck.kind else { return XCTFail("expected bottleneck first") }
        XCTAssertEqual(bottleneck.op, .indexAccess)
        XCTAssertEqual(bottleneck.loops, 20000)   // repeated inner side
        XCTAssertTrue(diag.insights.contains { if case .fullScan = $0.kind { true } else { false } })
    }

    // MARK: Diagnosis

    func testWastefulFilterAndBottleneckFromRealMySQLTree() {
        let tree =
            "-> Filter: ((cast(visit.inserted_at as date) = '2026-08-07') and (visit.log_type = 'member_checkin'))  (cost=119076 rows=743877) (actual time=0.68..2302 rows=413 loops=1)\n" +
            "    -> Index lookup on visit using branch_id (branch_id = 164) (reverse)  (cost=119076 rows=1.67e+6) (actual time=0.676..2165 rows=963054 loops=1)"
        let plan = PlanParser.parse(result: treeResult(tree), format: .mysqlTree, engine: .mysql)!

        let diag = PlanDiagnostics.diagnose(plan)
        XCTAssertEqual(diag.totalTimeMS, 2302)

        // The index lookup owns the time; the filter is the wasteful one.
        let bottleneck = try! XCTUnwrap(diag.insights.first)
        guard case .bottleneck(let share) = bottleneck.kind else {
            return XCTFail("expected bottleneck first, got \(bottleneck.kind)")
        }
        XCTAssertGreaterThan(share, 0.9)
        XCTAssertEqual(bottleneck.op, .indexAccess)
        XCTAssertEqual(bottleneck.relation, "visit · branch_id")

        let wasteful = try! XCTUnwrap(diag.insights.first { if case .wastefulFilter = $0.kind { true } else { false } })
        guard case .wastefulFilter(let read, let kept) = wasteful.kind else { return XCTFail() }
        XCTAssertEqual(read, 963054)
        XCTAssertEqual(kept, 413)
        XCTAssertEqual(wasteful.op, .filter)
        // One insight per node: the filter's misestimate does not double-report.
        XCTAssertEqual(diag.insights.filter { $0.id == wasteful.id }.count, 1)
    }

    func testFullScanFlaggedWithoutAnalyze() {
        // Plain EXPLAIN: no measured time, so no bottleneck — but a big seq scan
        // is still worth surfacing from the estimate alone.
        let plan = PlanParser.parse(result: jsonResult("""
        [{"Plan": {"Node Type": "Seq Scan", "Relation Name": "events", "Plan Rows": 80000}}]
        """), format: .json, engine: .postgres)!

        let diag = PlanDiagnostics.diagnose(plan)
        XCTAssertNil(diag.totalTimeMS)
        XCTAssertFalse(diag.insights.contains { if case .bottleneck = $0.kind { true } else { false } })
        let scan = try! XCTUnwrap(diag.insights.first { if case .fullScan = $0.kind { true } else { false } })
        XCTAssertEqual(scan.op, .fullScan)
        XCTAssertEqual(scan.relation, "events")
    }

    func testFastCleanPlanYieldsNoInsights() {
        // A small indexed lookup with well-matched estimates: nothing to say.
        let plan = PlanParser.parse(result: jsonResult("""
        [{"Plan": {
            "Node Type": "Index Scan", "Relation Name": "users", "Index Name": "users_pkey",
            "Plan Rows": 1, "Actual Rows": 1, "Actual Loops": 1, "Actual Total Time": 0.03},
          "Execution Time": 0.05}]
        """), format: .json, engine: .postgres)!

        // A 0.05 ms query has nothing to optimize: below the time floor, not even
        // a bottleneck — the card stays hidden.
        let diag = PlanDiagnostics.diagnose(plan)
        XCTAssertTrue(diag.insights.isEmpty)
    }

    // MARK: Real captured plans (guard against false positives)

    func testTemporaryTableScanIsNotFlaggedAsFullScan() {
        // A GROUP BY spools into a temp table MySQL then scans — that scan is not a
        // missing index, and the single-row inner lookup (loops=6.96e6, est 1) is
        // not a misestimate once compared per loop.
        let tree =
            "-> Limit: 20 row(s)  (actual time=7766..7766 rows=20 loops=1)\n" +
            "    -> Sort: c DESC, limit input to 20 row(s) per chunk  (actual time=7766..7766 rows=20 loops=1)\n" +
            "        -> Table scan on <temporary>  (actual time=7737..7752 rows=213304 loops=1)\n" +
            "            -> Aggregate using temporary table  (actual time=7737..7737 rows=213304 loops=1)\n" +
            "                -> Nested loop inner join  (cost=3e+6 rows=5.39e+6) (actual time=6.48..6300 rows=6.96e+6 loops=1)\n" +
            "                    -> Filter: ((v.inserted_at >= TIMESTAMP'2024-01-01') and (v.member_id is not null))  (cost=1.11e+6 rows=5.39e+6) (actual time=6.47..4399 rows=6.96e+6 loops=1)\n" +
            "                        -> Covering index scan on v using idx_visit_member_branch_logtype_date  (cost=1.11e+6 rows=10.8e+6) (actual time=1.33..2689 rows=10.9e+6 loops=1)\n" +
            "                    -> Single-row covering index lookup on m using PRIMARY (id = v.member_id)  (cost=0.25 rows=1) (actual time=134e-6..156e-6 rows=1 loops=6.96e+6)"
        let plan = PlanParser.parse(result: treeResult(tree), format: .mysqlTree, engine: .mysql)!

        func find(_ pred: (PlanNode) -> Bool, _ node: PlanNode) -> PlanNode? {
            if pred(node) { return node }
            for child in node.children { if let hit = find(pred, child) { return hit } }
            return nil
        }
        // The scientific loop count parsed, so the deep lookup has real metrics.
        let lookup = try! XCTUnwrap(find({ $0.label.contains("Single-row") }, plan.root))
        XCTAssertEqual(lookup.loops, 6_960_000)
        XCTAssertFalse(lookup.warnings.contains { if case .rowsMisestimate = $0 { true } else { false } })

        let diag = PlanDiagnostics.diagnose(plan)
        // No "reads a whole table" cause: the only big scan is the temp spool.
        XCTAssertFalse(diag.insights.contains { if case .fullScan = $0.kind { true } else { false } })
    }

    func testSortWithLimitIsNotAMisestimate() {
        // Sort output is post-LIMIT (50), far below its 632080 estimate — not a
        // planner miss. The real scan underneath still reads the whole table.
        let tree =
            "-> Limit: 50 row(s)  (cost=64946 rows=50) (actual time=1479..1479 rows=50 loops=1)\n" +
            "    -> Sort: `member`.note, limit input to 50 row(s) per chunk  (cost=64946 rows=632080) (actual time=1479..1479 rows=50 loops=1)\n" +
            "        -> Table scan on member  (cost=64946 rows=632080) (actual time=0.0295..1069 rows=682451 loops=1)"
        let plan = PlanParser.parse(result: treeResult(tree), format: .mysqlTree, engine: .mysql)!

        func find(_ pred: (PlanNode) -> Bool, _ node: PlanNode) -> PlanNode? {
            if pred(node) { return node }
            for child in node.children { if let hit = find(pred, child) { return hit } }
            return nil
        }
        let sort = try! XCTUnwrap(find({ $0.label == "Sort" }, plan.root))
        XCTAssertFalse(sort.warnings.contains { if case .rowsMisestimate = $0 { true } else { false } })

        let diag = PlanDiagnostics.diagnose(plan)
        XCTAssertTrue(diag.insights.contains { if case .fullScan = $0.kind { true } else { false } })
        // Bottleneck is the full scan of the real table, not the sort.
        let bottleneck = try! XCTUnwrap(diag.insights.first)
        XCTAssertEqual(bottleneck.op, .fullScan)
        XCTAssertEqual(bottleneck.relation, "member")
    }
}
