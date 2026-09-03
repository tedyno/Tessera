import Foundation

/// One searchable thing in the ⌘K palette: a connection, or a schema, table,
/// column or index inside one. Flat and `Sendable` on purpose — the index is
/// built once on the main actor from the schema trees, and the search then runs
/// over it off the main actor, without the tree graph itself crossing a thread.
public struct SpotlightEntry: Sendable, Hashable {
    public enum Kind: Int, Sendable, Hashable {
        case connection, schema, table, column, index
    }

    public let kind: Kind
    public let profileID: UUID
    public let connectionName: String
    /// Organizer breadcrumb (workspace → … → folder) leading to the connection.
    public let path: [String]
    public let schema: String?
    public let table: String?
    public let column: String?
    public let indexName: String?
    /// The title pre-folded for matching. Folding every candidate per keystroke is
    /// most of what the search does, so it is done once when the index is built.
    public let lowerTitle: String

    public init(kind: Kind, profileID: UUID, connectionName: String, path: [String],
                schema: String? = nil, table: String? = nil, column: String? = nil,
                indexName: String? = nil, lowerTitle: String) {
        self.kind = kind
        self.profileID = profileID
        self.connectionName = connectionName
        self.path = path
        self.schema = schema
        self.table = table
        self.column = column
        self.indexName = indexName
        self.lowerTitle = lowerTitle
    }

    public var title: String {
        switch kind {
        case .connection: connectionName
        case .schema: schema ?? ""
        case .table: table ?? ""
        case .column: column ?? ""
        case .index: indexName ?? ""
        }
    }
}

/// Matching and ranking for the ⌘K palette.
///
/// Pure and free of any UI type, so it can run on a background task over a
/// snapshot of the index: on a machine with a few large schemas cached the index
/// runs to hundreds of thousands of entries, and scanning it takes long enough to
/// drop frames if it happens on the main actor.
public enum SpotlightSearch {
    /// Entries whose title contains `needle`, best matches first, capped at `limit`.
    /// `needle` is expected already trimmed and lowercased (`normalize`).
    public static func matches(in entries: [SpotlightEntry], needle: String,
                               limit: Int = 80) -> [SpotlightEntry] {
        guard !needle.isEmpty else { return [] }
        let hits = entries.filter { $0.lowerTitle.contains(needle) }
        return Array(ranked(hits, needle: needle).prefix(limit))
    }

    /// What `matches` expects its needle to look like.
    public static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Exact matches first, then names that start with the term, then the rest —
    /// typing a full table name should not bury it under columns that merely
    /// contain it. Ties keep a stable kind order and sort by name.
    static func ranked(_ entries: [SpotlightEntry], needle: String) -> [SpotlightEntry] {
        func rank(_ entry: SpotlightEntry) -> Int {
            if entry.lowerTitle == needle { return 0 }
            if entry.lowerTitle.hasPrefix(needle) { return 1 }
            return 2
        }
        return entries.sorted { left, right in
            let (l, r) = (rank(left), rank(right))
            if l != r { return l < r }
            if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }
}
