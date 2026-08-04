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
///
/// Lives in `~/Library/Caches`, not Application Support: it is derived data that a
/// reconnect rebuilds, so it is fine for the system to purge it — unlike the
/// organizer, profiles, history and saved queries, which the user would miss.
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
            for: .cachesDirectory, in: .userDomainMask,
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

    /// Encodes the cache to JSON bytes. Split from `write` so a caller can encode
    /// on its own isolation — reading the value graph while it exclusively owns it —
    /// and hand only the resulting flat `Data` to a background task. The schema
    /// graph (whose COW buffers are shared with live UI state) then never crosses a
    /// thread boundary; only the bytes do.
    public func encode(_ cache: [UUID: CachedSchema]) -> Data? {
        let raw = Dictionary(uniqueKeysWithValues: cache.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(raw)
    }

    /// Writes pre-encoded bytes to the cache file. Safe to call off the main actor.
    public func write(_ data: Data) {
        try? PrivateFile.write(data, to: fileURL)
    }

    /// Convenience for synchronous callers and tests: encode then write in one call.
    public func save(_ cache: [UUID: CachedSchema]) {
        guard let data = encode(cache) else { return }
        write(data)
    }
}
