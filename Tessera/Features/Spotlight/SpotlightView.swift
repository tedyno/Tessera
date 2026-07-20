import SwiftUI

/// A search hit across all visited connections' schemas.
/// What the search is restricted to. `all` is the default; Tab moves to the next.
enum SpotlightCategory: String, CaseIterable, Identifiable {
    case all, connections, schemas, tables, columns, indexes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .connections: String(localized: "Connections")
        case .schemas: String(localized: "Schemas")
        case .tables: String(localized: "Tables")
        case .columns: String(localized: "Columns")
        case .indexes: String(localized: "Indexes")
        }
    }

    func accepts(_ kind: SpotlightResult.Kind) -> Bool {
        switch self {
        case .all: true
        case .connections: kind == .connection
        case .schemas: kind == .schema
        case .tables: kind == .table
        case .columns: kind == .column
        case .indexes: kind == .index
        }
    }
}

struct SpotlightResult: Identifiable, Hashable {
    enum Kind { case connection, schema, table, column, index }

    let id = UUID()
    let kind: Kind
    let profileID: UUID
    let connectionName: String
    /// Organizer breadcrumb (workspace → … → folder) leading to the connection.
    let path: [String]
    let schema: String?
    let table: String?
    let column: String?
    var indexName: String? = nil
    /// True when this came from the on-disk cache rather than a live connection.
    var isCached: Bool = false

    var title: String {
        switch kind {
        case .connection: connectionName
        case .schema: schema ?? ""
        case .table: table ?? ""
        case .column: column ?? ""
        case .index: indexName ?? ""
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
        case .index: "Index · \(locationPath) · \(schema ?? "").\(table ?? "")"
        }
    }

    var systemImage: String {
        switch kind {
        case .connection: "cylinder.split.1x2"
        case .schema: "circle.grid.2x2"
        case .table: "tablecells"
        case .column: "square.grid.3x3"
        case .index: "number.square"
        }
    }
}

/// Spotlight-style global search overlay (opened with a double-Shift). Type to
/// filter; ↑/↓ to move; Return to open.
struct SpotlightView: View {
    let app: AppModel
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var category: SpotlightCategory = .all
    @FocusState private var focused: Bool

    /// Ranked matches, then narrowed to the chosen category.
    private var results: [SpotlightResult] {
        app.spotlightResults(query: query).filter { category.accepts($0.kind) }
    }

    /// How many matches each category would show, so an empty one is visibly empty
    /// instead of looking broken when you Tab onto it.
    private var counts: [SpotlightCategory: Int] {
        let all = app.spotlightResults(query: query)
        return Dictionary(uniqueKeysWithValues: SpotlightCategory.allCases.map { category in
            (category, all.filter { category.accepts($0.kind) }.count)
        })
    }

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
                    // One handler only: a plain .tab handler would swallow the event
                    // before the modifier-aware one could see Shift.
                    .onKeyPress(keys: [.tab], phases: .down) { press in
                        cycleCategory(press.modifiers.contains(.shift) ? -1 : 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            categoryBar
            Divider()
            content
        }
        .frame(width: 640, height: 440)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onAppear { focused = true }
    }

    /// PhpStorm-style scope chips; Tab moves to the next, ⇧Tab back.
    private var categoryBar: some View {
        let counts = counts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SpotlightCategory.allCases) { option in
                    let count = counts[option] ?? 0
                    Button {
                        category = option
                        selectedIndex = 0
                    } label: {
                        HStack(spacing: 4) {
                            Text(option.title)
                            if !query.isEmpty {
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(option == category ? Color.accentColor.opacity(0.25) : Color.clear,
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(option == category ? AnyShapeStyle(.primary)
                                     : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func cycleCategory(_ delta: Int) {
        let all = SpotlightCategory.allCases
        guard let current = all.firstIndex(of: category) else { return }
        let next = (current + delta + all.count) % all.count
        category = all[next]
        selectedIndex = 0
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
            if result.isCached, result.kind != .connection {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("From the cached schema — this connection isn't open")
            }
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
