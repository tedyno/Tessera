import SwiftUI

/// Column 3 — detail with tabs, SQL editor and results table. Phase 0: a static
/// skeleton following the mockup. The live editor (STTextView), query execution
/// and streamed table arrive in Phases 1/7/8.
struct DetailView: View {
    private let sql = """
    SELECT o.id, c.name, o.total, o.status, o.created_at
    FROM orders o
    JOIN customers c ON c.id = o.customer_id
    WHERE o.created_at >= '2026-06-01'
      AND o.status IN ('paid', 'shipped')
    ORDER BY o.created_at DESC
    LIMIT 200;
    """

    private let rows: [ResultRow] = [
        .init(id: 1042, name: "Emma Wilson", total: "1,249.00", status: "paid", created: "2026-07-18 09:41:22"),
        .init(id: 1041, name: "Liam Smith", total: "389.00", status: "shipped", created: "2026-07-18 08:12:04"),
        .init(id: 1040, name: "Olivia Brown", total: "2,780.00", status: "paid", created: "2026-07-17 21:55:10"),
        .init(id: 1039, name: "Noah Jones", total: "156.00", status: "shipped", created: "2026-07-17 18:30:47"),
        .init(id: 1038, name: "Ava Davis", total: "4,120.00", status: "paid", created: "2026-07-17 15:02:33"),
        .init(id: 1037, name: "Lucas Miller", total: "899.00", status: "paid", created: "2026-07-17 11:47:59"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            editorToolbar
            Divider()
            ScrollView {
                Text(sql)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 150)
            Divider()
            resultsTable
            statusBar
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tab("orders", active: true)
            tab("customers", active: false)
            Spacer()
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tab(_ title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(active ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
        .overlay(alignment: .trailing) { Divider() }
    }

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            Button { } label: { Label("Run", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button { } label: { Label("Stop", systemImage: "stop.fill") }
                .controlSize(.small)
                .disabled(true)
            Text("Last run: 142 ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(6)
    }

    private var resultsTable: some View {
        Table(rows) {
            TableColumn("id") { Text("\($0.id)").monospaced() }
                .width(64)
            TableColumn("name", value: \.name)
            TableColumn("total") { Text($0.total).monospaced() }
                .width(110)
            TableColumn("status", value: \.status)
                .width(120)
            TableColumn("created_at") { Text($0.created).monospaced() }
                .width(190)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("200 rows")
            Text("142 ms")
            Text("5 columns")
            Spacer()
            Text("PostgreSQL 16.3 · TLS")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

private struct ResultRow: Identifiable {
    let id: Int
    let name: String
    let total: String
    let status: String
    let created: String
}
