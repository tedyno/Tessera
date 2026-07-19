import Foundation

/// A named SQL snippet the user bookmarked for reuse.
public struct SavedQuery: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var sql: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, sql: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.sql = sql
        self.createdAt = createdAt
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
        try? encoder.encode(entries).write(to: fileURL, options: [.atomic])
    }
}
