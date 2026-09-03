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

    /// Refuses a write that would drop connections the file already holds, unless
    /// the caller says removals are expected.
    ///
    /// Connection parameters exist nowhere else, so the dangerous write is not a bad
    /// value but a *short list*: a decode that silently yielded nothing, a seed that
    /// thought this was a first run, a migration that dropped what it did not
    /// recognise. All of those look like an ordinary save. Making deletion something
    /// a caller has to ask for turns that class of bug into a refused write and a
    /// thrown error instead of a file the user cannot get back.
    public func save(_ profiles: [ConnectionProfile], allowingRemovals: Bool = false) throws {
        try write(try encode(profiles, allowingRemovals: allowingRemovals))
    }

    /// Runs the removal guard and encodes the list. Throws exactly what `save`
    /// throws, so a caller that writes the bytes later still learns *now* that the
    /// write was refused — the refusal is the part the user has to be told about.
    ///
    /// Split from `write` so the caller can hand the flat `Data` to a background
    /// writer instead of blocking on the backup and the atomic replace.
    public func encode(_ profiles: [ConnectionProfile], allowingRemovals: Bool = false) throws -> Data {
        if !allowingRemovals {
            try refuseSilentRemovals(in: profiles)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }

    /// Keeps what's there now, then replaces it. Safe to call off the main actor.
    ///
    /// Throws what the write throws: a full disk or a permission problem loses the
    /// user's connections just as surely as a refused save does, so the caller —
    /// even a background one — has to be able to say so.
    public func write(_ data: Data) throws {
        // Keep what's there now before replacing it — including when the caller
        // is about to write a shorter list than the file holds.
        backups.capture(fileURL)
        try PrivateFile.write(data, to: fileURL)
    }

    /// Throws when `profiles` is missing an id the stored file still has.
    private func refuseSilentRemovals(in profiles: [ConnectionProfile]) throws {
        guard fileExists else { return }
        let stored: [ConnectionProfile]
        do {
            stored = try load()
        } catch {
            // The file cannot be read, so there is no way to tell what this write
            // would destroy. Refusing is the only safe answer — and the app already
            // stops and reports an unreadable store rather than carrying on.
            throw ProfileStoreError.unreadableStore(underlying: String(describing: error))
        }
        let keeping = Set(profiles.map(\.id))
        let dropped = stored.filter { !keeping.contains($0.id) }
        guard dropped.isEmpty else {
            throw ProfileStoreError.wouldRemoveProfiles(names: dropped.map(\.name))
        }
    }
}

public enum ProfileStoreError: Error, Equatable, CustomStringConvertible {
    /// A save would have dropped stored connections without being asked to.
    case wouldRemoveProfiles(names: [String])
    /// A save was attempted over a file that could not be read first.
    case unreadableStore(underlying: String)

    public var description: String {
        switch self {
        case .wouldRemoveProfiles(let names):
            "Refused to save: this would have removed \(names.count) saved "
                + "connection(s) that nothing asked to delete — \(names.joined(separator: ", "))."
        case .unreadableStore(let underlying):
            "Refused to save over a connections file that could not be read: \(underlying)"
        }
    }
}
