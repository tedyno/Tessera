import Foundation

/// Loads and atomically saves the organizer to a JSON file.
public struct OrganizerStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/<bundleID>/organizer.json` (creates the directory).
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

    public func save(_ document: OrganizerDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try PrivateFile.write(data, to: fileURL)
    }
}
