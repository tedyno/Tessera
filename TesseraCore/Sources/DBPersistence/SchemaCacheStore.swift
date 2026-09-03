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
        bundleID: String = StorageIdentity.current,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schema-cache.json", isDirectory: false)
    }

    /// One file per connection, next to where the single-file cache used to live.
    /// A schema refresh then re-encodes and rewrites only the connection that
    /// changed; with the whole cache in one file, refreshing one connection meant
    /// re-encoding every schema on the machine — hundreds of milliseconds on the
    /// main actor for a handful of large databases.
    public var directoryURL: URL { fileURL.deletingPathExtension() }

    private func entryURL(_ profileID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(profileID.uuidString).json", isDirectory: false)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads every cached schema, folding in (and retiring) a single-file cache
    /// left by an earlier version.
    public func load() -> [UUID: CachedSchema] {
        var cache = migrateLegacyFile()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let entry = try? Self.decoder().decode(CachedSchema.self, from: data)
            else { continue }
            cache[id] = entry
        }
        return cache
    }

    /// Splits a pre-0.31 `schema-cache.json` into per-connection files and removes
    /// it. Returns what it held, so the first launch after an update still has its
    /// cache even if writing the new files fails.
    @discardableResult
    private func migrateLegacyFile() -> [UUID: CachedSchema] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? Self.decoder().decode([String: CachedSchema].self, from: data)
        else { return [:] }
        var cache: [UUID: CachedSchema] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else { continue }
            cache[id] = value
            if let encoded = encode(value) { write(encoded, for: id) }
        }
        try? FileManager.default.removeItem(at: fileURL)
        return cache
    }

    /// Encodes one connection's schema. Split from `write` so a caller can encode
    /// on its own isolation — reading the value graph while it exclusively owns it —
    /// and hand only the resulting flat `Data` to a background task. The schema
    /// graph (whose COW buffers are shared with live UI state) then never crosses a
    /// thread boundary; only the bytes do.
    public func encode(_ schema: CachedSchema) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(schema)
    }

    /// Writes pre-encoded bytes as one connection's cache. Safe to call off the
    /// main actor.
    public func write(_ data: Data, for profileID: UUID) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? PrivateFile.write(data, to: entryURL(profileID))
    }

    /// Drops a connection's cached schema. Safe to call off the main actor.
    public func remove(_ profileID: UUID) {
        try? FileManager.default.removeItem(at: entryURL(profileID))
    }

    /// Convenience for synchronous callers and tests: encode then write in one call.
    public func save(_ cache: [UUID: CachedSchema]) {
        for (id, entry) in cache {
            guard let data = encode(entry) else { continue }
            write(data, for: id)
        }
    }
}
