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

    var body: some View {
        VStack(spacing: 0) {
            if parsedVersion == tab.resultVersion, let plan {
                planHeader(plan)
                Divider()
                if tab.showRawPlan {
                    // A JSON plan is one multiline cell — the grid would show
                    // just its first line. Render the raw payload as text;
                    // SQLite's row-shaped plan keeps the grid.
                    if tab.currentPlan?.format == .json, let raw = rawPayload {
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
                        VStack(alignment: .leading, spacing: 1) {
                            PlanNodeRow(node: plan.root, isAnalyzed: plan.isAnalyzed)
                        }
                        .padding(8)
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
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    PlanNodeRow(node: child, isAnalyzed: isAnalyzed)
                }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
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
            }
            Spacer(minLength: 16)
            metrics
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background((node.shareOfTotal ?? 0) >= 0.2
                    ? shareColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .help(extraHelp)
    }

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
                .frame(width: max(share * 60, share > 0 ? 2 : 0))
        }
        .frame(width: 60, height: 5)
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
