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

    public func save(_ entries: [SavedQuery]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? PrivateFile.write(data, to: fileURL)
    }
}
