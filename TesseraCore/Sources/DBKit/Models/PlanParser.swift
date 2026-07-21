import Foundation

/// Turns an EXPLAIN result fetched through the normal query path into a
/// `QueryPlan` tree. Every failure mode returns nil — the caller then shows the
/// raw grid unchanged, so a server version with an unexpected plan shape can
/// never regress below today's behavior.
public enum PlanParser {

    /// Refuse absurdly large plan payloads rather than parse them.
    static let maxPayloadBytes = 512 * 1024

    public static func parse(result: QueryResult, format: ExplainPlanFormat,
                             engine: DatabaseKind) -> QueryPlan? {
        switch format {
        case .json:
            guard let text = jsonPayload(from: result) else { return nil }
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            switch engine {
            case .postgres:
                return postgresPlan(json)
            case .mysql, .mariadb:
                return mysqlPlan(json)
            case .sqlite:
                return nil
            }
        case .sqliteQueryPlan:
            return sqlitePlan(result)
        }
    }

    /// The JSON document arrives as the cells of column 0 — normally one row,
    /// but a driver may split a large document across rows.
    private static func jsonPayload(from result: QueryResult) -> String? {
        guard !result.columns.isEmpty else { return nil }
        let text = result.rows.compactMap { $0.first?.text }.joined(separator: "\n")
        guard !text.isEmpty, text.utf8.count <= maxPayloadBytes else { return nil }
        return text
    }

    // MARK: - PostgreSQL (EXPLAIN (FORMAT JSON))

    private static func postgresPlan(_ json: Any) -> QueryPlan? {
        guard let top = (json as? [Any])?.first as? [String: Any],
              let planDict = top["Plan"] as? [String: Any] else { return nil }
        let root = postgresNode(planDict, underGather: false)
        return finish(root: root,
                      planningTimeMS: double(top["Planning Time"]),
                      executionTimeMS: double(top["Execution Time"]))
    }

    /// Keys mapped to first-class fields; everything else scalar goes to `extra`.
    private static let pgConsumedKeys: Set<String> = [
        "Node Type", "Join Type", "Relation Name", "Index Name", "Alias",
        "Plan Rows", "Actual Rows", "Actual Loops", "Total Cost", "Startup Cost",
        "Actual Total Time", "Actual Startup Time", "Plans", "Plan Width",
        "Parent Relationship", "Parallel Aware", "Async Capable",
    ]
    private static let pgDetailKeys = [
        "Index Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter",
        "Recheck Cond", "Sort Key", "Group Key",
    ]

    private static func postgresNode(_ dict: [String: Any], underGather: Bool) -> PlanNode {
        var label = (dict["Node Type"] as? String) ?? "?"
        if let join = dict["Join Type"] as? String, join != "Inner" {
            label += " (\(join))"
        }
        var relation = dict["Relation Name"] as? String
        if let index = dict["Index Name"] as? String {
            relation = relation.map { "\($0) · \(index)" } ?? index
        }

        var details: [String] = []
        for key in pgDetailKeys {
            if let value = dict[key] as? String {
                details.append("\(key): \(value)")
            } else if let list = dict[key] as? [Any] {
                let joined = list.compactMap { $0 as? String }.joined(separator: ", ")
                if !joined.isEmpty { details.append("\(key): \(joined)") }
            }
        }

        let loops = double(dict["Actual Loops"])
        var extra: [PlanField] = []
        var warnings: [PlanWarning] = []
        for (key, value) in dict {
            guard !pgConsumedKeys.contains(key), !pgDetailKeys.contains(key) else { continue }
            guard let scalar = scalarText(value) else { continue }
            extra.append(PlanField(key: key, value: scalar))
            if key == "Sort Method", scalar.lowercased().contains("external") {
                warnings.append(.spilledToDisk)
            }
            if key == "Sort Space Type", scalar == "Disk" {
                warnings.append(.spilledToDisk)
            }
        }
        extra.sort { $0.key < $1.key }

        let nodeType = (dict["Node Type"] as? String) ?? ""
        let isGather = nodeType.hasPrefix("Gather")
        let children = (dict["Plans"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .map { postgresNode($0, underGather: isGather) } ?? []

        // "Actual Total Time" is a per-loop average. On the inner side of a
        // nested loop the loops run sequentially, so ×loops gives inclusive
        // time; under a Gather they are concurrent worker processes, and
        // multiplying would sum CPU time past the query's own wall clock —
        // keep the per-worker average there. Rows stay ×loops either way
        // (workers produce disjoint row sets).
        return PlanNode(
            label: label,
            relation: relation,
            parentRelationship: dict["Parent Relationship"] as? String,
            detail: details.isEmpty ? nil : details.joined(separator: " · "),
            estimatedRows: double(dict["Plan Rows"]),
            actualRows: multiplied(double(dict["Actual Rows"]), by: loops),
            estimatedCost: double(dict["Total Cost"]),
            actualTotalTimeMS: underGather
                ? double(dict["Actual Total Time"])
                : multiplied(double(dict["Actual Total Time"]), by: loops),
            loops: loops,
            warnings: warnings,
            extra: extra,
            children: children)
    }

    // MARK: - MySQL / MariaDB (EXPLAIN FORMAT=JSON, ANALYZE FORMAT=JSON)

    /// Container keys that become labeled nodes, walked in this order so the
    /// tree is deterministic despite JSON dictionaries being unordered.
    private static let mysqlContainers: [(key: String, label: String)] = [
        ("nested_loop", "Nested Loop"),
        ("ordering_operation", "Ordering"),
        ("grouping_operation", "Grouping"),
        ("duplicates_removal", "Distinct"),
        ("windowing", "Window"),
        ("materialized_from_subquery", "Materialized Subquery"),
        ("attached_subqueries", "Attached Subqueries"),
        ("optimized_away_subqueries", "Optimized Away Subqueries"),
        ("union_result", "Union"),
        ("query_specifications", ""),
        ("subqueries", "Subqueries"),
        ("query_block", ""),
    ]
    private static let mysqlContainerKeys = Set(mysqlContainers.map(\.key))

    private static func mysqlPlan(_ json: Any) -> QueryPlan? {
        guard let top = json as? [String: Any],
              let block = top["query_block"] as? [String: Any] else { return nil }
        var root = PlanNode(
            label: "Query Block",
            estimatedCost: costInfo(block["cost_info"]),
            actualTotalTimeMS: double(block["r_total_time_ms"]),
            children: mysqlNodes(in: block))
        guard containsTable(root) else { return nil }
        // A block that only wraps a single operation reads better collapsed.
        if root.children.count == 1, root.estimatedCost == nil, root.actualTotalTimeMS == nil {
            root = root.children[0]
        }
        return finish(root: root, planningTimeMS: nil, executionTimeMS: nil)
    }

    /// Walks one JSON dictionary and returns the plan nodes found in it, in the
    /// deterministic container order; unknown containers are descended without
    /// creating a node so newer server versions still yield their tables.
    private static func mysqlNodes(in dict: [String: Any]) -> [PlanNode] {
        var nodes: [PlanNode] = []
        if let table = dict["table"] as? [String: Any] {
            nodes.append(mysqlTableNode(table))
        }
        for container in mysqlContainers where dict[container.key] != nil {
            let inner = mysqlChildren(of: dict[container.key]!)
            guard !inner.isEmpty else { continue }
            if container.label.isEmpty {
                nodes.append(contentsOf: inner)
            } else {
                nodes.append(PlanNode(label: container.label, children: inner))
            }
        }
        // Generic descent through unknown containers (deterministic key order).
        for key in dict.keys.sorted() {
            guard key != "table", !mysqlContainerKeys.contains(key) else { continue }
            if let value = dict[key] {
                nodes.append(contentsOf: mysqlChildren(of: value))
            }
        }
        return nodes
    }

    private static func mysqlChildren(of value: Any) -> [PlanNode] {
        if let dict = value as? [String: Any] { return mysqlNodes(in: dict) }
        if let list = value as? [Any] {
            return list.flatMap(mysqlChildren(of:))
        }
        return []
    }

    private static let mysqlConsumedKeys: Set<String> = [
        "table_name", "access_type", "key", "rows_examined_per_scan", "rows",
        "r_rows", "r_total_time_ms", "cost_info", "attached_condition",
        "used_columns", "possible_keys", "key_length", "used_key_parts", "ref",
    ]

    private static func mysqlTableNode(_ dict: [String: Any]) -> PlanNode {
        let name = (dict["table_name"] as? String) ?? "?"
        let access = dict["access_type"] as? String
        let estimated = double(dict["rows_examined_per_scan"]) ?? double(dict["rows"])
        let actual = double(dict["r_rows"])

        var warnings: [PlanWarning] = []
        if access == "ALL", (actual ?? estimated ?? 0) >= 10_000 {
            warnings.append(.sequentialScan)
        }

        var extra: [PlanField] = []
        for (key, value) in dict {
            guard !mysqlConsumedKeys.contains(key), !mysqlContainerKeys.contains(key) else { continue }
            if let scalar = scalarText(value) { extra.append(PlanField(key: key, value: scalar)) }
        }
        extra.sort { $0.key < $1.key }

        // Nested containers can live inside the table dict (materialized subqueries).
        var inner = dict
        for key in mysqlConsumedKeys { inner.removeValue(forKey: key) }
        let children = mysqlNodes(in: inner)

        return PlanNode(
            label: access.map { "\(name) (\($0))" } ?? name,
            relation: dict["key"] as? String,
            detail: dict["attached_condition"] as? String,
            estimatedRows: estimated,
            actualRows: actual,
            estimatedCost: costInfo(dict["cost_info"]),
            actualTotalTimeMS: double(dict["r_total_time_ms"]),
            warnings: warnings,
            extra: extra,
            children: children)
    }

    /// MySQL renders costs as strings inside cost_info; MariaDB as numbers.
    private static func costInfo(_ value: Any?) -> Double? {
        guard let dict = value as? [String: Any] else { return nil }
        return double(dict["query_cost"]) ?? double(dict["read_cost"])
    }

    private static func containsTable(_ node: PlanNode) -> Bool {
        if node.relation != nil || node.estimatedRows != nil || node.actualRows != nil
            || node.label.contains("(") { return true }
        return node.children.contains(where: containsTable)
    }

    // MARK: - SQLite (EXPLAIN QUERY PLAN)

    private static func sqlitePlan(_ result: QueryResult) -> QueryPlan? {
        func columnIndex(_ name: String) -> Int? {
            result.columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard let idCol = columnIndex("id"), let parentCol = columnIndex("parent"),
              let detailCol = columnIndex("detail"), !result.rows.isEmpty else { return nil }

        struct Row { let id: Int; let parent: Int; let detail: String }
        var rows: [Row] = []
        for cells in result.rows {
            guard cells.indices.contains(idCol), cells.indices.contains(parentCol),
                  cells.indices.contains(detailCol),
                  let id = cells[idCol].text.flatMap(Int.init),
                  let parent = cells[parentCol].text.flatMap(Int.init),
                  let detail = cells[detailCol].text else { return nil }
            rows.append(Row(id: id, parent: parent, detail: detail))
        }

        // Guards corrupt input (duplicate ids forming a cycle) from recursing
        // forever — real EXPLAIN QUERY PLAN ids are unique and increasing.
        func node(for row: Row, seen: Set<Int>) -> PlanNode {
            var seen = seen
            seen.insert(row.id)
            let children = rows
                .filter { $0.parent == row.id && !seen.contains($0.id) }
                .map { node(for: $0, seen: seen) }
            var warnings: [PlanWarning] = []
            let upper = row.detail.uppercased()
            if upper.hasPrefix("SCAN "), !upper.contains("USING INDEX") {
                warnings.append(.sequentialScan)
            }
            return PlanNode(label: row.detail, warnings: warnings, children: children)
        }

        let ids = Set(rows.map(\.id))
        let tops = rows.filter { !ids.contains($0.parent) }.map { node(for: $0, seen: []) }
        guard !tops.isEmpty else { return nil }
        let root = tops.count == 1 ? tops[0] : PlanNode(label: "Query Plan", children: tops)
        return finish(root: root, planningTimeMS: nil, executionTimeMS: nil)
    }

    // MARK: - Shared post-pass

    /// Assigns depth-first ids, derives self time and share-of-total, and adds
    /// the warnings that need both estimated and actual figures.
    private static func finish(root: PlanNode, planningTimeMS: Double?,
                               executionTimeMS: Double?) -> QueryPlan {
        var nextID = 0
        var isAnalyzed = false

        func annotate(_ node: PlanNode) -> PlanNode {
            var node = node
            node.id = nextID
            nextID += 1
            if node.actualRows != nil || node.actualTotalTimeMS != nil { isAnalyzed = true }

            if let inclusive = node.actualTotalTimeMS {
                // An InitPlan child (e.g. a materialized CTE) is timed again
                // inside the sibling that consumes it — subtracting it here
                // would count it twice and clamp this node's self time to 0.
                let childTime = node.children
                    .filter { $0.parentRelationship != "InitPlan" }
                    .compactMap(\.actualTotalTimeMS).reduce(0, +)
                node.selfTimeMS = max(0, inclusive - childTime)
            }
            if let estimated = node.estimatedRows, let actual = node.actualRows {
                let factor = max(estimated, actual) / max(min(estimated, actual), 1)
                if factor >= 10 {
                    node.warnings.append(.rowsMisestimate(factor: factor))
                }
            }
            if node.label == "Seq Scan",
               (node.actualRows ?? node.estimatedRows ?? 0) >= 10_000,
               !node.warnings.contains(.sequentialScan) {
                node.warnings.append(.sequentialScan)
            }
            node.children = node.children.map(annotate)
            return node
        }

        var annotated = annotate(root)
        let total = annotated.actualTotalTimeMS ?? totalSelfTime(annotated)
        if total > 0 {
            annotated = applyShare(annotated, total: total)
        }
        return QueryPlan(root: annotated,
                         planningTimeMS: planningTimeMS,
                         executionTimeMS: executionTimeMS,
                         isAnalyzed: isAnalyzed)
    }

    private static func totalSelfTime(_ node: PlanNode) -> Double {
        (node.selfTimeMS ?? 0) + node.children.map(totalSelfTime).reduce(0, +)
    }

    private static func applyShare(_ node: PlanNode, total: Double) -> PlanNode {
        var node = node
        if let selfTime = node.selfTimeMS {
            node.shareOfTotal = min(1, selfTime / total)
        }
        node.children = node.children.map { applyShare($0, total: total) }
        return node
    }

    // MARK: - Value coercion

    /// Numbers arrive as NSNumber from Postgres plans and as strings from
    /// MySQL's cost_info — accept both.
    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func multiplied(_ value: Double?, by factor: Double?) -> Double? {
        guard let value else { return nil }
        return value * max(factor ?? 1, 1)
    }

    private static func scalarText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            return number === kCFBooleanTrue || number === kCFBooleanFalse
                ? (number.boolValue ? "true" : "false")
                : number.stringValue
        }
        return nil
    }
}
