import Foundation

/// One key/value the parser didn't map to a first-class field — surfaced in the
/// plan view as extra detail rather than dropped.
public struct PlanField: Sendable, Hashable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Something the planner output reveals that likely deserves attention.
public enum PlanWarning: Sendable, Hashable {
    /// Actual vs estimated rows off by ≥ 10× (factor is the larger ratio).
    case rowsMisestimate(factor: Double)
    /// Sequential scan (Seq Scan / access type ALL) over many rows.
    case sequentialScan
    /// Postgres: a sort that spilled to disk instead of staying in memory.
    case spilledToDisk
}

/// One operation of a query plan. Metrics are optional because plain EXPLAIN
/// has no actuals and SQLite's plan has no numbers at all.
public struct PlanNode: Sendable, Hashable, Identifiable {
    /// Depth-first index — deterministic for a given plan, stable for tests.
    public var id: Int
    /// Operation name, e.g. "Seq Scan", "Nested Loop", "users (ref)".
    public var label: String
    /// Table or index the operation touches, when known.
    public var relation: String?
    /// Postgres "Parent Relationship" ("InitPlan", "SubPlan", …) — an InitPlan
    /// child's time is also baked into the sibling that consumes it, so the
    /// self-time derivation must not subtract it twice.
    public var parentRelationship: String?
    /// One-line condition: filter, join cond, attached_condition.
    public var detail: String?
    public var estimatedRows: Double?
    /// Total rows produced (per-loop actuals multiplied by loop count).
    public var actualRows: Double?
    public var estimatedCost: Double?
    /// Inclusive wall time in ms (children included), loops multiplied in.
    public var actualTotalTimeMS: Double?
    /// Inclusive time minus the children's inclusive time, clamped ≥ 0.
    public var selfTimeMS: Double?
    /// selfTimeMS as a fraction of the plan's total, 0…1. Analyze only.
    public var shareOfTotal: Double?
    public var loops: Double?
    public var warnings: [PlanWarning]
    public var extra: [PlanField]
    public var children: [PlanNode]

    public init(
        id: Int = 0,
        label: String,
        relation: String? = nil,
        parentRelationship: String? = nil,
        detail: String? = nil,
        estimatedRows: Double? = nil,
        actualRows: Double? = nil,
        estimatedCost: Double? = nil,
        actualTotalTimeMS: Double? = nil,
        selfTimeMS: Double? = nil,
        shareOfTotal: Double? = nil,
        loops: Double? = nil,
        warnings: [PlanWarning] = [],
        extra: [PlanField] = [],
        children: [PlanNode] = []
    ) {
        self.id = id
        self.label = label
        self.relation = relation
        self.parentRelationship = parentRelationship
        self.detail = detail
        self.estimatedRows = estimatedRows
        self.actualRows = actualRows
        self.estimatedCost = estimatedCost
        self.actualTotalTimeMS = actualTotalTimeMS
        self.selfTimeMS = selfTimeMS
        self.shareOfTotal = shareOfTotal
        self.loops = loops
        self.warnings = warnings
        self.extra = extra
        self.children = children
    }
}

/// A parsed query plan ready for tree rendering.
public struct QueryPlan: Sendable, Hashable {
    public var root: PlanNode
    public var planningTimeMS: Double?
    public var executionTimeMS: Double?
    /// Whether actual (measured) metrics exist — drives the share bars.
    public var isAnalyzed: Bool

    public init(root: PlanNode,
                planningTimeMS: Double? = nil,
                executionTimeMS: Double? = nil,
                isAnalyzed: Bool = false) {
        self.root = root
        self.planningTimeMS = planningTimeMS
        self.executionTimeMS = executionTimeMS
        self.isAnalyzed = isAnalyzed
    }
}
