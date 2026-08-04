import Foundation

/// One executed query, recorded for the history panel.
public struct QueryHistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var sql: String
    public var connectionName: String
    /// The connection this query ran against, so re-running from history targets the
    /// original database. Optional/`nil` for entries recorded before this was tracked.
    public var profileID: UUID?
    /// Set when the entry came from a table (data) view, so it reopens as one rather
    /// than as a console query. `nil` for a plain query.
    public var schema: String?
    public var table: String?
    public var timestamp: Date
    public var rowCount: Int?
    public var elapsedMS: Int?

    /// True when this entry was a table (data) view rather than a typed query.
    public var isTableView: Bool { table != nil }

    public init(
        id: UUID = UUID(),
        sql: String,
        connectionName: String,
        profileID: UUID? = nil,
        schema: String? = nil,
        table: String? = nil,
        timestamp: Date,
        rowCount: Int? = nil,
        elapsedMS: Int? = nil
    ) {
        self.id = id
        self.sql = sql
        self.connectionName = connectionName
        self.profileID = profileID
        self.schema = schema
        self.table = table
        self.timestamp = timestamp
        self.rowCount = rowCount
        self.elapsedMS = elapsedMS
    }
}

/// Append-only query history persisted as JSON (newest first, capped).
public struct QueryHistoryStore: Sendable {
    public let fileURL: URL
    public let limit: Int

    public init(fileURL: URL, limit: Int = 500) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public static func defaultURL(
        bundleID: String = "io.github.tedyno.tessera",
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json", isDirectory: false)
    }

    public func load() -> [QueryHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([QueryHistoryEntry].self, from: data)) ?? []
    }

    /// Persists the given entries (newest-first, capped to `limit`).
    /// Caps to `limit` and encodes to JSON bytes. Split from `write` so a caller can
    /// encode on its own isolation (reading the entries while it exclusively owns
    /// them) and hand only the flat `Data` to a background task — the entry array
    /// never crosses a thread boundary, only the bytes do.
    public func encode(_ entries: [QueryHistoryEntry]) -> Data? {
        let capped = entries.count > limit ? Array(entries.prefix(limit)) : entries
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(capped)
    }

    /// Writes pre-encoded bytes to the history file. Safe to call off the main actor.
    public func write(_ data: Data) {
        try? PrivateFile.write(data, to: fileURL)
    }

    public func save(_ entries: [QueryHistoryEntry]) {
        guard let data = encode(entries) else { return }
        write(data)
    }

    /// Prepends an entry (newest first), caps to `limit`, and persists.
    @discardableResult
    public func append(_ entry: QueryHistoryEntry) -> [QueryHistoryEntry] {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > limit { entries = Array(entries.prefix(limit)) }
        save(entries)
        return entries
    }
}
