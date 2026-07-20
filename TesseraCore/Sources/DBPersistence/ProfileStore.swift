import Foundation
import DBKit

/// Loads and atomically saves the list of `ConnectionProfile`s as JSON.
/// Deliberately separate from the organizer: arrangement (who lives in which
/// folder) lives in `OrganizerStore`, connection parameters here, secrets in the
/// Keychain.
public struct ProfileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/<bundleID>/profiles.json` (creates the directory).
    public static func defaultURL(
        bundleID: String = "io.github.tedyno.tessera",
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

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try PrivateFile.write(data, to: fileURL)
    }
}
