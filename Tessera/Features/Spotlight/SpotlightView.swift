import SwiftUI
import DBKit

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
    /// The same cases the Core index uses, so a match maps straight across.
    typealias Kind = SpotlightEntry.Kind

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
        case .schema: String(localized: "Schema · \(locationPath)")
        case .table: String(localized: "Table · \(locationPath) · \(schema ?? "")")
        case .column: String(localized: "Column · \(locationPath) · \(schema ?? "").\(table ?? "")")
        case .index: String(localized: "Index · \(locationPath) · \(schema ?? "").\(table ?? "")")
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
    /// The full ranked match set, recomputed only when the query changes — not on
    /// every keystroke-independent re-render (arrow-key navigation, category
    /// switches). Searching every connection's cached schema is the expensive part,
    /// so it must run once per query, never twice per render.
    @State private var allResults: [SpotlightResult] = []
    /// The query `allResults` was computed for. While it lags behind `query`, a
    /// search is pending (debounce) or running — the UI shows "Searching…" then,
    /// not "No matches".
    @State private var searchedQuery = ""
    /// Debounces the search so a fast typist doesn't trigger a run per keystroke.
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// The full set narrowed to the chosen category — cheap array filtering.
    private var results: [SpotlightResult] {
        allResults.filter { category.accepts($0.kind) }
    }

    /// How many matches each category would show, so an empty one is visibly empty
    /// instead of looking broken when you Tab onto it. One pass over the cached set.
    private var counts: [SpotlightCategory: Int] {
        var counts: [SpotlightCategory: Int] = [.all: allResults.count]
        for result in allResults {
            for option in SpotlightCategory.allCases where option != .all && option.accepts(result.kind) {
                counts[option, default: 0] += 1
            }
        }
        return counts
    }

    private func refresh() async {
        let query = query
        let results = await app.spotlightResults(query: query)
        // The palette may have moved on while the scan ran in the background.
        guard query == self.query else { return }
        allResults = results
        searchedQuery = query
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
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            searchTask?.cancel()
            searchTask = Task {
                // Long enough that a normal typing cadence updates once you pause,
                // not on every keystroke (which read as flicker).
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        .onAppear {
            focused = true
            searchTask = Task { await refresh() }
        }
        .onDisappear { searchTask?.cancel() }
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
            if query.isEmpty {
                ContentUnavailableView(
                    "Search everywhere", systemImage: "magnifyingglass",
                    description: Text("Find a connection, schema, table or column across all connections you've opened."))
                    .frame(maxHeight: .infinity)
            } else if query != searchedQuery {
                // A search is pending (debounce) or in flight — don't flash "No
                // matches" for the previous query's empty set.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No matches", systemImage: "magnifyingglass",
                    description: Text("Nothing matches “\(query)”."))
                    .frame(maxHeight: .infinity)
            }
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
                .scrollContentBackground(.hidden)
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
