import Foundation
import DBKit

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
///
/// The cap is per connection: a busy database would otherwise evict every other
/// connection's history from a single shared budget. `limit` remains as a backstop
/// on the file as a whole.
public struct QueryHistoryStore: Sendable {
    public let fileURL: URL
    /// Total number of entries kept across all connections (safety net).
    public let limit: Int
    /// Number of entries kept per connection — the cap that actually bites.
    public let perConnection: Int

    public init(fileURL: URL, limit: Int = 2000, perConnection: Int = 30) {
        self.fileURL = fileURL
        self.limit = limit
        self.perConnection = perConnection
    }

    public static func defaultURL(
        bundleID: String = StorageIdentity.current,
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(capped(entries))
    }

    /// Writes pre-encoded bytes to the history file. Safe to call off the main actor.
    public func write(_ data: Data) {
        try? PrivateFile.write(data, to: fileURL)
    }

    public func save(_ entries: [QueryHistoryEntry]) {
        guard let data = encode(entries) else { return }
        write(data)
    }

    /// Prepends an entry (newest first), applies the caps, and persists.
    @discardableResult
    public func append(_ entry: QueryHistoryEntry) -> [QueryHistoryEntry] {
        var entries = load()
        entries.insert(entry, at: 0)
        entries = capped(entries)
        save(entries)
        return entries
    }

    // MARK: Pure entry maths

    /// Applies this store's caps: at most `perConnection` entries for each
    /// connection, then `limit` overall. Entries stay newest-first.
    public func capped(_ entries: [QueryHistoryEntry]) -> [QueryHistoryEntry] {
        Self.capped(entries, perConnection: perConnection, total: limit)
    }

    /// Keeps the newest `perConnection` entries of every connection, then trims the
    /// result to `total`. Entries recorded before connections were tracked
    /// (`profileID == nil`) share one bucket of their own.
    public static func capped(_ entries: [QueryHistoryEntry],
                              perConnection: Int,
                              total: Int) -> [QueryHistoryEntry] {
        var counts: [UUID: Int] = [:]
        var legacy = 0
        var kept: [QueryHistoryEntry] = []
        kept.reserveCapacity(min(entries.count, total))
        for entry in entries {
            if let id = entry.profileID {
                let seen = counts[id, default: 0]
                guard seen < perConnection else { continue }
                counts[id] = seen + 1
            } else {
                guard legacy < perConnection else { continue }
                legacy += 1
            }
            kept.append(entry)
            if kept.count == total { break }
        }
        return kept
    }

    /// The entries belonging to one connection. Legacy entries (no `profileID`)
    /// belong to no connection and so appear only in the unfiltered list.
    public static func entries(_ entries: [QueryHistoryEntry],
                               for profileID: UUID?) -> [QueryHistoryEntry] {
        guard let profileID else { return entries }
        return entries.filter { $0.profileID == profileID }
    }

    /// Position of the newest matching entry for a connection, used to collapse a
    /// re-run into the entry it repeats. Searching by connection (rather than just
    /// looking at the head) keeps the collapse working when runs on two connections
    /// interleave.
    public static func newestIndex(in entries: [QueryHistoryEntry],
                                   profileID: UUID?,
                                   sql: String,
                                   table: String?) -> Int? {
        entries.firstIndex {
            $0.profileID == profileID && $0.sql == sql && $0.table == table
        }
    }

    /// Drops every entry of one connection — for when its profile is deleted.
    public static func removing(_ entries: [QueryHistoryEntry],
                                profileID: UUID) -> [QueryHistoryEntry] {
        entries.filter { $0.profileID != profileID }
    }
}
