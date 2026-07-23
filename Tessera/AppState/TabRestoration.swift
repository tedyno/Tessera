import Foundation

/// One open tab, reduced to what recreates it on the next launch — no results,
/// no live connections, just the shape. Queries don't re-run on restore; a
/// restored tab loads its data on the first explicit Run/Refresh.
struct SavedTab: Codable {
    enum Kind: String, Codable { case console, data, diagram }

    struct SavedSortKey: Codable { var column: String; var ascending: Bool }

    var kind: Kind
    var profileID: UUID?
    var title: String
    var sql: String
    var dataSchema: String?
    var dataTable: String?
    var filterWhere: String
    /// Multi-column sort in priority order. Optional so documents saved before
    /// multi-sort (which had `sortColumn`/`sortAscending`) still decode, as nil.
    var sortOrder: [SavedSortKey]?
    var pageLimit: Int
    var diagramSchema: String?
    var diagramTable: String?
}

/// The tiling layout, serialised: a leaf lists tab indices into the document's
/// `tabs` (with its active one), a split records its axis, the first child's
/// fraction, and its children. Optional so older documents (no layout) still load.
struct SavedPane: Codable {
    // Leaf.
    var tabs: [Int]?
    var active: Int?
    // Split.
    var axis: String?
    var fraction: Double?
    var children: [SavedPane]?
}

struct SavedTabsDocument: Codable {
    var tabs: [SavedTab] = []
    var activeIndex: Int?
    var layout: SavedPane?
}

/// Persists the open tabs as JSON in Application Support, so quitting and
/// relaunching brings the workspace back.
enum SavedTabsStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Tessera",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("open-tabs.json")
    }

    static func load() -> SavedTabsDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedTabsDocument.self, from: data)
    }

    static func save(_ document: SavedTabsDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
