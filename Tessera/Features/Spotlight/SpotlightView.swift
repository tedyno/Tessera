import SwiftUI

/// A search hit across all visited connections' schemas.
struct SpotlightResult: Identifiable, Hashable {
    enum Kind { case connection, schema, table, column }

    let id = UUID()
    let kind: Kind
    let profileID: UUID
    let connectionName: String
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

    var subtitle: String {
        switch kind {
        case .connection: "Connection"
        case .schema: "Schema · \(connectionName)"
        case .table: "Table · \(connectionName) / \(schema ?? "")"
        case .column: "Column · \(connectionName) / \(schema ?? "").\(table ?? "")"
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

/// Spotlight-style global search overlay (opened with a double-Shift).
struct SpotlightView: View {
    let app: AppModel
    @State private var query = ""

    private var results: [SpotlightResult] { app.spotlightResults(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search connections, schemas, tables, columns…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { if let first = results.first { app.open(first) } }
            }
            .padding(14)
            Divider()
            if results.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Search everywhere" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty
                                      ? "Find a connection, schema, table or column across all connections you've opened."
                                      : "Nothing matches “\(query)”."))
                    .frame(maxHeight: .infinity)
            } else {
                List(results) { result in
                    HStack(spacing: 10) {
                        Image(systemName: result.systemImage)
                            .frame(width: 18)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.title)
                            Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.open(result) }
                }
            }
        }
        .frame(width: 640, height: 440)
    }
}
