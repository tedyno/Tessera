import Foundation

/// A named SQL snippet the user bookmarked for reuse.
public struct SavedQuery: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var sql: String
    public var createdAt: Date
    /// Profile the query was saved on; nil on entries from before this field
    /// existed — those stay visible on every connection.
    public var connectionID: UUID?

    public init(id: UUID = UUID(), title: String, sql: String, createdAt: Date,
                connectionID: UUID? = nil) {
        self.id = id
        self.title = title
        self.sql = sql
        self.createdAt = createdAt
        self.connectionID = connectionID
    }
}

/// Saved queries persisted as JSON (newest first).
public struct SavedQueryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
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
        return dir.appendingPathComponent("saved-queries.json", isDirectory: false)
    }

    public func load() -> [SavedQuery] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedQuery].self, from: data)) ?? []
    }

    /// Encodes to JSON bytes. Split from `write` so a caller can encode on its own
    /// isolation (reading the entries while it exclusively owns them) and hand only
    /// the flat `Data` to a background task — the entry array never crosses a thread
    /// boundary, only the bytes do.
    public func encode(_ entries: [SavedQuery]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(entries)
    }

    /// Writes pre-encoded bytes to the saved-queries file. Safe to call off the main actor.
    public func write(_ data: Data) {
        try? PrivateFile.write(data, to: fileURL)
    }

    public func save(_ entries: [SavedQuery]) {
        guard let data = encode(entries) else { return }
        write(data)
    }
}
