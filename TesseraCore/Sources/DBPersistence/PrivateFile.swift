import Foundation

/// Writes the app's data files so only their owner can read them.
///
/// `~/Library` is already `700`, so another account can't reach these — but the
/// files themselves default to `644`, which is more than anything here needs.
/// Connection parameters, query history, and cached schema names are all worth
/// keeping to the owner, so every store writes through this.
enum PrivateFile {
    /// Owner read/write only.
    static let mode: NSNumber = 0o600

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        // Set after writing: an atomic write replaces the file, taking its own
        // permissions with it, so setting them beforehand would be undone.
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
