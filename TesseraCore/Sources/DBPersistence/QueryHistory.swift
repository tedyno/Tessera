import Foundation

/// One executed query, recorded for the history panel.
public struct QueryHistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var sql: String
    public var connectionName: String
    public var timestamp: Date
    public var rowCount: Int?
    public var elapsedMS: Int?

    public init(
        id: UUID = UUID(),
        sql: String,
        connectionName: String,
        timestamp: Date,
        rowCount: Int? = nil,
        elapsedMS: Int? = nil
    ) {
        self.id = id
        self.sql = sql
        self.connectionName = connectionName
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
    public func save(_ entries: [QueryHistoryEntry]) {
        let capped = entries.count > limit ? Array(entries.prefix(limit)) : entries
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(capped).write(to: fileURL, options: [.atomic])
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
