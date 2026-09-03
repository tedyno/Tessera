import Foundation
import DBKit

/// Loads and atomically saves the organizer to a JSON file.
public struct OrganizerStore: Sendable {
    public let fileURL: URL
    /// Previous versions of the tree, kept next to the file — the arrangement of
    /// folders and connections is the user's work and can't be reconstructed.
    public let backups: StoreBackups

    public init(fileURL: URL, backups: StoreBackups? = nil) {
        self.fileURL = fileURL
        self.backups = backups ?? .alongside(fileURL)
    }

    /// `~/Library/Application Support/<bundleID>/organizer.json` (creates the directory).
    public static func defaultURL(
        bundleID: String = StorageIdentity.current,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("organizer.json", isDirectory: false)
    }

    /// Returns an empty document if the file does not exist yet.
    public func load() throws -> OrganizerDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return OrganizerDocument()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(OrganizerDocument.self, from: data)
    }

    /// Encodes the document to JSON bytes. Split from `write` so a caller can
    /// encode on its own isolation and hand only the flat `Data` to a background
    /// writer — the same split the history and schema-cache stores use, and what
    /// keeps a drag in the organizer from waiting on three file operations.
    public func encode(_ document: OrganizerDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Backs up what is there and writes the bytes. Safe to call off the main
    /// actor; throws what the write throws.
    public func write(_ data: Data) throws {
        backups.capture(fileURL)
        try PrivateFile.write(data, to: fileURL)
    }

    public func save(_ document: OrganizerDocument) throws {
        try write(try encode(document))
    }
}
