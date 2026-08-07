import Foundation

/// A plan node's operation in plain-language terms, so the UI can describe it in
/// words a non-expert reads. Classified from the label, so it works the same for
/// PostgreSQL, MySQL and SQLite. The UI owns the localized phrasing.
public enum PlanOpKind: Sendable, Hashable {
    /// Reads a whole table (Seq Scan / Table scan / SQLite SCAN).
    case fullScan
    /// Finds rows through an index (Index Scan / Index lookup / Bitmap / SEARCH … INDEX).
    case indexAccess
    /// Combines two inputs (Nested Loop / Hash Join / Merge Join / …).
    case join
    /// Builds a hash table for a join to probe.
    case hashBuild
    /// Gathers rows from parallel workers (Gather / Gather Merge).
    case gather
    /// Stashes rows to reuse them (Materialize / Memoize).
    case materialize
    /// Computes window functions (WindowAgg / Window).
    case window
    /// Removes duplicate rows (Unique / Distinct / duplicates removal).
    case distinct
    /// Combines several queries' results (Append / Union / Merge Append).
    case setOp
    /// Reads a subquery or CTE result (CTE Scan / Subquery Scan / InitPlan).
    case subquery
    /// Produces values without reading a table (Result).
    case compute
    case sort
    case aggregate
    case filter
    case limit
    /// Anything not worth a special phrase — the UI keeps the raw label.
    case other

    /// Best-effort category for a node, by its (engine-agnostic) label. Order is
    /// deliberate: the more specific compounds (Hash Join, HashAggregate) must be
    /// caught before the plain word they contain (Hash).
    public static func of(_ node: PlanNode) -> PlanOpKind {
        let l = node.label.lowercased()
        if l.contains("index") || l.contains("bitmap") { return .indexAccess }
        if l.contains("seq scan") || l.contains("table scan") || l.hasPrefix("scan ") { return .fullScan }
        if l.contains("join") || l.contains("loop") { return .join }
        if l.contains("aggreg") || l.contains("group") { return .aggregate }
        if l.contains("hash") { return .hashBuild }
        if l.contains("gather") { return .gather }
        if l.contains("materiali") || l.contains("memoize") { return .materialize }
        if l.contains("window") { return .window }
        if l.contains("unique") || l.contains("distinct") || l.contains("duplicat") { return .distinct }
        if l.contains("sort") { return .sort }
        if l.contains("append") || l.contains("union") { return .setOp }
        if l.contains("filter") { return .filter }
        if l.contains("limit") { return .limit }
        if l.contains("cte") || l.contains("subquer") || l.contains("subplan") || l.contains("initplan") {
            return .subquery
        }
        if l.contains("result") { return .compute }
        return .other
    }
}

/// One human-facing observation about a plan, pointing at the node it concerns
/// (`nodeID` is the plan's depth-first id, so the UI can scroll to / highlight it).
/// Structured, not prose — the app renders the localized sentence.
public struct PlanInsight: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Where the query spent most of its measured time (share is 0…1).
        case bottleneck(share: Double)
        /// A filter kept far fewer rows than its input produced.
        case wastefulFilter(read: Double, kept: Double)
        /// A full scan over a large table.
        case fullScan(rows: Double)
        /// Estimated vs actual rows diverged badly (factor ≥ 10).
        case misestimate(factor: Double)
        /// A sort that spilled to disk instead of staying in memory.
        case sortSpill
    }

    /// The node this concerns; also the Identifiable id (unique per plan).
    public var id: Int
    public var kind: Kind
    public var op: PlanOpKind
    public var relation: String?
    /// How many times the node ran — surfaced on the bottleneck to explain a
    /// cheap-per-call operation that turned expensive by repetition.
    public var loops: Double?

    public init(id: Int, kind: Kind, op: PlanOpKind, relation: String?, loops: Double? = nil) {
        self.id = id
        self.kind = kind
        self.op = op
        self.relation = relation
        self.loops = loops
    }
}

/// The plain-language reading of a plan: a total time and an ordered list of
/// insights, most important first. Empty when there is nothing worth saying
/// (e.g. a plain EXPLAIN with no measured time, or a trivially fast query).
public struct PlanDiagnosis: Sendable, Hashable {
    public var totalTimeMS: Double?
    public var insights: [PlanInsight]

    public var isEmpty: Bool { insights.isEmpty }

    public init(totalTimeMS: Double?, insights: [PlanInsight]) {
        self.totalTimeMS = totalTimeMS
        self.insights = insights
    }
}

/// Turns a parsed `QueryPlan` into plain-language insights. Pure and deterministic
/// — the rules lean on the metrics and warnings the parser already derived.
public enum PlanDiagnostics {

    /// A filter is "wasteful" when it read at least this many rows and kept at
    /// most this fraction of them — the shape of a scan that wanted an index.
    static let wastefulReadFloor: Double = 1_000
    static let wastefulKeepFraction: Double = 0.1
    /// A node must own at least this share of the total time to be called the
    /// bottleneck — below it, no single operation dominates.
    static let bottleneckShare: Double = 0.3
    /// Below this total time there's nothing worth optimizing, so don't point at a
    /// "bottleneck" — a sub-millisecond query reads as fine, not as a problem.
    static let bottleneckTimeFloorMS: Double = 10

    public static func diagnose(_ plan: QueryPlan) -> PlanDiagnosis {
        let all = flatten(plan.root)
        let total = plan.executionTimeMS ?? plan.root.actualTotalTimeMS
        var bottleneck: [PlanInsight] = []
        var insights: [PlanInsight] = []

        // 1. Where the time went: the single node with the biggest self-time share.
        //    Carries its loop count so the UI can add "ran N times" when repetition
        //    (not per-call cost) is what made it expensive.
        if plan.isAnalyzed, let total, total >= bottleneckTimeFloorMS,
           let hot = all.max(by: { ($0.shareOfTotal ?? 0) < ($1.shareOfTotal ?? 0) }),
           let share = hot.shareOfTotal, share >= bottleneckShare {
            bottleneck.append(PlanInsight(id: hot.id, kind: .bottleneck(share: share),
                                          op: .of(hot), relation: hot.relation, loops: hot.loops))
        }

        // 2. A filter that kept a small fraction of a large input — read many,
        //    returned few, the classic missing-index shape.
        for node in all where PlanOpKind.of(node) == .filter {
            guard let kept = node.actualRows,
                  let read = node.children.compactMap(\.actualRows).max(),
                  read >= wastefulReadFloor, kept <= read * wastefulKeepFraction else { continue }
            insights.append(PlanInsight(id: node.id, kind: .wastefulFilter(read: read, kept: kept),
                                        op: .filter,
                                        relation: node.relation ?? node.children.first?.relation))
        }

        // 3. Full scans over large tables.
        for node in all where node.warnings.contains(.sequentialScan) {
            let rows = node.actualRows ?? node.estimatedRows ?? 0
            insights.append(PlanInsight(id: node.id, kind: .fullScan(rows: rows),
                                        op: .fullScan, relation: node.relation))
        }

        // 4. The worst row-estimate miss (stale statistics territory).
        let misestimates = all.compactMap { node -> (PlanNode, Double)? in
            for case .rowsMisestimate(let factor) in node.warnings { return (node, factor) }
            return nil
        }
        if let worst = misestimates.max(by: { $0.1 < $1.1 }) {
            insights.append(PlanInsight(id: worst.0.id, kind: .misestimate(factor: worst.1),
                                        op: .of(worst.0), relation: worst.0.relation))
        }

        // 5. Sorts that spilled to disk.
        for node in all where node.warnings.contains(.spilledToDisk) {
            insights.append(PlanInsight(id: node.id, kind: .sortSpill, op: .sort, relation: node.relation))
        }

        // The bottleneck always leads; the causes below it are deduped among
        // themselves (one reason per node) but may share the bottleneck's node —
        // "94% is here" and "…because it read a million rows" are complementary.
        return PlanDiagnosis(totalTimeMS: total, insights: bottleneck + dedupedByNode(insights))
    }

    /// Keeps one insight per node — the first, since insights are appended in
    /// priority order, so the strongest reason for a node wins.
    private static func dedupedByNode(_ insights: [PlanInsight]) -> [PlanInsight] {
        var seen = Set<Int>()
        return insights.filter { seen.insert($0.id).inserted }
    }

    private static func flatten(_ node: PlanNode) -> [PlanNode] {
        [node] + node.children.flatMap(flatten)
    }
}
