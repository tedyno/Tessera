import Foundation
import DBKit

/// Loads and atomically saves the list of `ConnectionProfile`s as JSON.
/// Deliberately separate from the organizer: arrangement (who lives in which
/// folder) lives in `OrganizerStore`, connection parameters here, secrets in the
/// Keychain.
public struct ProfileStore: Sendable {
    public let fileURL: URL
    /// Previous versions, kept next to the file. Connection parameters can't be
    /// regenerated from anything else, so every write leaves the old content
    /// behind first.
    public let backups: StoreBackups

    public init(fileURL: URL, backups: StoreBackups? = nil) {
        self.fileURL = fileURL
        self.backups = backups ?? .alongside(fileURL)
    }

    /// `~/Library/Application Support/<bundleID>/profiles.json` (creates the directory).
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
        return dir.appendingPathComponent("profiles.json", isDirectory: false)
    }

    /// True when a profiles file is already on disk. The distinction matters:
    /// "no file yet" is a first run and may be seeded, while "a file we failed to
    /// read" must never be replaced — that would destroy the only copy of the
    /// user's connections.
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func load() throws -> [ConnectionProfile] {
        guard fileExists else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        // Keep what's there now before replacing it — including when the caller
        // is about to write a shorter list than the file holds.
        backups.capture(fileURL)
        try PrivateFile.write(data, to: fileURL)
    }
}
