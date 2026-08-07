import SwiftUI
import DBKit

/// Renders an EXPLAIN result as a collapsible plan tree with per-node metrics,
/// falling back to the raw grid when the payload doesn't parse (or when the
/// user flips the Tree/Raw toggle). Owns the parse cache: the plan is rebuilt
/// only when a new result arrives, so expansion state survives re-renders.
struct PlanResultView<Fallback: View>: View {
    @Bindable var tab: QueryTab
    let engine: DatabaseKind
    @ViewBuilder let fallback: () -> Fallback

    @State private var parsedVersion: Int?
    @State private var plan: QueryPlan?
    @State private var diagnosis: PlanDiagnosis?

    var body: some View {
        VStack(spacing: 0) {
            if parsedVersion == tab.resultVersion, let plan {
                planHeader(plan)
                Divider()
                if tab.showRawPlan {
                    // A JSON or MySQL-tree plan is one multiline cell — the grid
                    // would show just its first line. Render the raw payload as
                    // text; SQLite's row-shaped plan keeps the grid.
                    if tab.currentPlan?.format == .json || tab.currentPlan?.format == .mysqlTree,
                       let raw = rawPayload {
                        ScrollView([.vertical, .horizontal]) {
                            Text(verbatim: raw)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        fallback()
                    }
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let diagnosis, !diagnosis.isEmpty {
                                DiagnosisCard(diagnosis: diagnosis)
                            }
                            PlanNodeRow(node: plan.root, isAnalyzed: plan.isAnalyzed)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Fresh plan, fresh expansion state — node ids repeat
                        // across plans, so carried-over @State would collapse
                        // arbitrary rows of the new tree.
                        .id(parsedVersion)
                    }
                }
            } else {
                fallback()
            }
        }
        .onChange(of: tab.resultVersion, initial: true) { _, version in
            guard parsedVersion != version else { return }
            parsedVersion = version
            plan = tab.currentPlan.flatMap { request in
                tab.result.flatMap {
                    PlanParser.parse(result: $0, format: request.format, engine: engine)
                }
            }
            diagnosis = plan.map(PlanDiagnostics.diagnose)
        }
    }

    /// The plan document as the server sent it (column 0 of every row).
    private var rawPayload: String? {
        guard let result = tab.result else { return nil }
        let text = result.rows.compactMap { $0.first?.text }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private func planHeader(_ plan: QueryPlan) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab.showRawPlan) {
                Text("Tree").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("Show the plan as a tree or the raw server output")
            Spacer()
            if let planning = plan.planningTimeMS {
                Text("Planning \(Self.ms(planning)) ms")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let execution = plan.executionTimeMS {
                Text("Execution \(Self.ms(execution)) ms")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    static func ms(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1)))
    }
}

/// One plan operation: disclosure row with label, condition, metrics and a
/// share-of-total-time bar; children indent below. Expanded by default —
/// plans are small and the shape is the point.
private struct PlanNodeRow: View {
    let node: PlanNode
    let isAnalyzed: Bool
    @State private var expanded = true

    var body: some View {
        label
        if expanded {
            if node.children.count == 1 {
                // Single-child chains stay on the same level — the staircase
                // carried no information; only a real branch indents.
                PlanNodeRow(node: node.children[0], isAnalyzed: isAnalyzed)
            } else if !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(node.children) { child in
                        PlanNodeRow(node: child, isAnalyzed: isAnalyzed)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    // The disclosure lives inside the card — a gutter chevron
                    // floats detached from what it collapses.
                    if !node.children.isEmpty {
                        Button {
                            withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(node.warnings.enumerated()), id: \.offset) { _, warning in
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .help(Self.text(for: warning))
                    }
                    Text(verbatim: node.label)
                        .font(.callout.bold())
                    if let relation = node.relation {
                        Text(verbatim: relation)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = node.detail {
                    Text(verbatim: detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(detail)
                }
                // Plain-language gloss so the tree reads without knowing plan jargon.
                if let phrase = planOpPhrase(PlanOpKind.of(node)) {
                    Text(phrase)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 16)
            metrics
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        // Rounded panel per node; heat shows as a tinted border with only a
        // whisper of fill — a stronger wash turns muddy over the dark backdrop.
        .background(isHot ? shareColor.opacity(0.07) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isHot ? shareColor.opacity(0.5) : Color.primary.opacity(0.08)))
        .help(extraHelp)
    }

    private var isHot: Bool { (node.shareOfTotal ?? 0) >= 0.2 }

    private var metrics: some View {
        HStack(spacing: 10) {
            if let estimated = node.estimatedRows {
                metric(value: Self.rows(estimated), caption: Text("est. rows"))
            }
            if let actual = node.actualRows {
                metric(value: Self.rows(actual), caption: Text("actual rows"))
            }
            if let time = node.actualTotalTimeMS {
                metric(value: "\(PlanResultView<EmptyView>.ms(time)) ms", caption: Text("time"))
            } else if let cost = node.estimatedCost {
                metric(value: cost.formatted(.number.precision(.fractionLength(0...2))),
                       caption: Text("cost"))
            }
            if isAnalyzed {
                shareBar
            }
        }
    }

    private func metric(value: String, caption: Text) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: value).font(.caption.monospacedDigit())
            caption.font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    /// Fraction of the whole query's time spent in this node alone.
    private var shareBar: some View {
        let share = node.shareOfTotal ?? 0
        return ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(shareColor)
                .frame(width: max(share * 90, share > 0 ? 2 : 0))
        }
        .frame(width: 90, height: 5)
        .help(Text(verbatim: share.formatted(.percent.precision(.fractionLength(0...1)))))
    }

    private var shareColor: Color {
        let share = node.shareOfTotal ?? 0
        if share >= 0.5 { return .red }
        if share >= 0.2 { return .orange }
        return .accentColor
    }

    private var extraHelp: String {
        node.extra.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    static func rows(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }

    static func text(for warning: PlanWarning) -> String {
        switch warning {
        case .rowsMisestimate(let factor):
            String(localized: "Row estimate off by ×\(factor.formatted(.number.precision(.fractionLength(0))))")
        case .sequentialScan:
            String(localized: "Sequential scan over many rows")
        case .spilledToDisk:
            String(localized: "Sort spilled to disk")
        }
    }
}

/// The plain-language "what the query did" summary above the tree: total time,
/// where the time went, and why it's slow — readable without knowing EXPLAIN.
private struct DiagnosisCard: View {
    let diagnosis: PlanDiagnosis

    var body: some View {
        let bottleneck = diagnosis.insights.first { if case .bottleneck = $0.kind { true } else { false } }
        // Drop a full-scan cause that repeats the bottleneck's own node — the
        // "where the time went" line already named it as reading the whole table.
        let causes = diagnosis.insights.filter { insight in
            if case .bottleneck = insight.kind { return false }
            if case .fullScan = insight.kind, insight.id == bottleneck?.id { return false }
            return true
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("What the query did", systemImage: "lightbulb")
                    .font(.callout.bold())
                Spacer()
                if let total = diagnosis.totalTimeMS {
                    Text("Took \(planDuration(total))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let bottleneck {
                section(Text("Where the time went"), [bottleneck])
            }
            if !causes.isEmpty {
                section(Text("Why it's slow"), causes)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.3)))
    }

    private func section(_ title: Text, _ insights: [PlanInsight]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            title.font(.caption.smallCaps()).foregroundStyle(.secondary)
            ForEach(insights) { insight in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                    line(for: insight).font(.callout).foregroundStyle(.primary)
                }
            }
        }
    }

    private func line(for insight: PlanInsight) -> Text {
        switch insight.kind {
        case .bottleneck(let share):
            let pct = share.formatted(.percent.precision(.fractionLength(0)))
            var base: Text
            if let rel = insight.relation, let op = planOpPhrase(insight.op) {
                base = Text("\(pct) of the time went here — it \(op) (\(rel)).")
            } else if let op = planOpPhrase(insight.op) {
                base = Text("\(pct) of the time went here — it \(op).")
            } else if let rel = insight.relation {
                base = Text("\(pct) of the time went here, on \(rel).")
            } else {
                base = Text("\(pct) of the time went here.")
            }
            // Repetition, not per-call cost, is often what makes a loop's inner
            // side expensive — spell it out when it ran many times.
            if let loops = insight.loops, loops >= 10 {
                base = base + Text(" ") + Text("It ran \(planRows(loops)) times.")
            }
            return base
        case .wastefulFilter(let read, let kept):
            if kept == 0 {
                return Text("Read \(planRows(read)) rows but none matched — no index covers the filter, so the whole table was scanned for nothing.")
            }
            return Text("Read \(planRows(read)) rows but kept only \(planRows(kept)) — no index covers the filter, so almost everything read was thrown away.")
        case .fullScan(let rows):
            if let rel = insight.relation {
                return Text("Reads the whole \(rel) table (\(planRows(rows)) rows) — there's no usable index.")
            }
            return Text("Reads a whole table (\(planRows(rows)) rows) — there's no usable index.")
        case .misestimate(let factor):
            let f = factor.formatted(.number.precision(.fractionLength(0)))
            return Text("The row estimate was off by ×\(f) — the table's statistics may be stale.")
        case .sortSpill:
            return Text("A sort didn't fit in memory and spilled to disk.")
        }
    }
}

/// A plan operation in one plain phrase (nil = keep the raw label). Shared by the
/// summary card and the per-node gloss so the wording stays identical.
private func planOpPhrase(_ op: PlanOpKind) -> String? {
    switch op {
    case .fullScan: String(localized: "reads the whole table")
    case .indexAccess: String(localized: "looks rows up through an index")
    case .join: String(localized: "combines two tables")
    case .hashBuild: String(localized: "builds a lookup table for the join")
    case .gather: String(localized: "collects rows from parallel workers")
    case .materialize: String(localized: "stores rows aside to reuse them")
    case .window: String(localized: "computes window functions")
    case .distinct: String(localized: "removes duplicate rows")
    case .setOp: String(localized: "combines results of several queries")
    case .subquery: String(localized: "reads a subquery's result")
    case .compute: String(localized: "computes values without reading a table")
    case .sort: String(localized: "sorts the rows")
    case .aggregate: String(localized: "aggregates the rows")
    case .filter: String(localized: "keeps only the matching rows")
    case .limit: String(localized: "limits the number of rows")
    case .other: nil
    }
}

private func planRows(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
}

private func planDuration(_ ms: Double) -> String {
    if ms >= 1000 {
        return "\((ms / 1000).formatted(.number.precision(.fractionLength(ms >= 10_000 ? 0 : 1)))) s"
    }
    return "\(ms.formatted(.number.precision(.fractionLength(ms < 10 ? 2 : 0)))) ms"
}
