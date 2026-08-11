import Foundation

/// Keeps previous versions of the small JSON stores that can't be regenerated —
/// the connection profiles and the organizer tree.
///
/// Two levels, because the two ways these files get lost need different answers:
///
/// * `<name>.previous.json` — the content from immediately before the last write,
///   for the case you notice at once ("that save shouldn't have happened").
/// * `<name>-YYYY-MM-DD.json` — the state at the first write of each day, kept
///   for a fortnight, for the case you notice much later. Keeping the *first*
///   write of the day is deliberate: it is the state before anything that day
///   touched the file.
///
/// Backups are copies of what is already on disk, taken before it is replaced,
/// so an unreadable or truncated file gets preserved exactly as found rather
/// than being re-encoded from memory.
public struct StoreBackups: Sendable {
    public let directory: URL
    /// How many daily snapshots to keep.
    public let keepDays: Int

    public init(directory: URL, keepDays: Int = 14) {
        self.directory = directory
        self.keepDays = keepDays
    }

    /// The conventional location next to the store itself.
    public static func alongside(_ fileURL: URL, keepDays: Int = 14) -> StoreBackups {
        StoreBackups(directory: fileURL.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true), keepDays: keepDays)
    }

    /// Copies the file's current content aside. Does nothing when there is no file
    /// yet, and never throws — a backup problem must not stop the app from saving.
    public func capture(_ fileURL: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension

        let previous = directory.appendingPathComponent("\(name).previous.\(ext)")
        try? PrivateFile.write(data, to: previous)

        let daily = directory.appendingPathComponent("\(name)-\(Self.day(now)).\(ext)")
        if !fileManager.fileExists(atPath: daily.path) {
            try? PrivateFile.write(data, to: daily)
        }
        prune(name: name, ext: ext)
    }

    /// Daily snapshots of one store, newest first.
    public func snapshots(of name: String, ext: String = "json") -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter { $0.lastPathComponent.hasPrefix("\(name)-")
                   && $0.pathExtension == ext }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func prune(name: String, ext: String) {
        let stale = snapshots(of: name, ext: ext).dropFirst(max(keepDays, 1))
        for url in stale { try? FileManager.default.removeItem(at: url) }
    }

    /// `YYYY-MM-DD` in the local calendar, so a "day" means the user's day.
    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
