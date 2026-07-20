import Foundation
import DBKit

/// One connection's introspected schema, kept so search can reach connections that
/// aren't currently open. Structure only — table, column and index **names**; never
/// any row data, and never anything secret.
public struct CachedSchema: Codable, Sendable {
    public var tree: DatabaseTree
    /// When it was read, so the UI can say how stale it is.
    public var updatedAt: Date

    public init(tree: DatabaseTree, updatedAt: Date) {
        self.tree = tree
        self.updatedAt = updatedAt
    }
}

/// Persists introspected schemas as JSON, keyed by profile id.
public struct SchemaCacheStore: Sendable {
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
        return dir.appendingPathComponent("schema-cache.json", isDirectory: false)
    }

    public func load() -> [UUID: CachedSchema] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([String: CachedSchema].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    public func save(_ cache: [UUID: CachedSchema]) {
        let raw = Dictionary(uniqueKeysWithValues: cache.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(raw) else { return }
        try? PrivateFile.write(data, to: fileURL)
    }
}
