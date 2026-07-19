import SwiftUI

/// A search hit across all visited connections' schemas.
struct SpotlightResult: Identifiable, Hashable {
    enum Kind { case connection, schema, table, column }

    let id = UUID()
    let kind: Kind
    let profileID: UUID
    let connectionName: String
    /// Organizer breadcrumb (workspace → … → folder) leading to the connection.
    let path: [String]
    let schema: String?
    let table: String?
    let column: String?

    var title: String {
        switch kind {
        case .connection: connectionName
        case .schema: schema ?? ""
        case .table: table ?? ""
        case .column: column ?? ""
        }
    }

    /// e.g. "Acme / Production / production-pg".
    var locationPath: String { (path + [connectionName]).joined(separator: " / ") }

    var subtitle: String {
        switch kind {
        case .connection: locationPath
        case .schema: "Schema · \(locationPath)"
        case .table: "Table · \(locationPath) · \(schema ?? "")"
        case .column: "Column · \(locationPath) · \(schema ?? "").\(table ?? "")"
        }
    }

    var systemImage: String {
        switch kind {
        case .connection: "cylinder.split.1x2"
        case .schema: "circle.grid.2x2"
        case .table: "tablecells"
        case .column: "square.grid.3x3"
        }
    }
}

/// Spotlight-style global search overlay (opened with a double-Shift). Type to
/// filter; ↑/↓ to move; Return to open.
struct SpotlightView: View {
    let app: AppModel
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var results: [SpotlightResult] { app.spotlightResults(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search connections, schemas, tables, columns…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { openSelected(); return .handled }
            }
            .padding(14)
            Divider()
            content
        }
        .frame(width: 640, height: 440)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var content: some View {
        if results.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "Search everywhere" : "No matches",
                systemImage: "magnifyingglass",
                description: Text(query.isEmpty
                                  ? "Find a connection, schema, table or column across all connections you've opened."
                                  : "Nothing matches “\(query)”."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        row(result, selected: index == selectedIndex)
                            .id(result.id)
                            .listRowBackground(index == selectedIndex ? Color.accentColor.opacity(0.22) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { app.open(result) }
                    }
                }
                .onChange(of: selectedIndex) { _, index in
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }
        }
    }

    private func row(_ result: SpotlightResult, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.systemImage).frame(width: 18).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(selectedIndex + delta, count - 1))
    }

    private func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        app.open(results[selectedIndex])
    }
}
