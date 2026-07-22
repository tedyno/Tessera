import Foundation

extension Notification.Name {
    /// Posted when the MCP settings change, so the app restarts the server.
    static let mcpSettingsChanged = Notification.Name("tessera.mcpSettingsChanged")
}

/// Where exports are written by default. Persisted in UserDefaults; defaults to the
/// user's Downloads folder.
enum ExportSettings {
    static let directoryKey = "tessera.exportDirectory"

    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: directoryKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func setDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: directoryKey)
    }

    static func resetDirectory() {
        UserDefaults.standard.removeObject(forKey: directoryKey)
    }

    /// Hard cap on rows pulled into memory for one query. 0 = unlimited.
    static let maxRowsKey = "tessera.maxRows"
    static var maxRows: Int {
        get { UserDefaults.standard.object(forKey: maxRowsKey) as? Int ?? 10_000 }
        set { UserDefaults.standard.set(newValue, forKey: maxRowsKey) }
    }

    /// Show the finished export in Finder. On by default.
    static let revealKey = "tessera.revealAfterExport"
    static var revealAfterExport: Bool {
        get { UserDefaults.standard.object(forKey: revealKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: revealKey) }
    }

    /// A canonical, timestamped file name, e.g. `shop_2026-07-19_134217.sql.gz`.
    /// Seconds included, so repeated exports of the same table never propose
    /// the same name.
    static func fileName(base: String, extension fileExtension: String = "sql") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let safe = base.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return "\(String(safe))_\(formatter.string(from: Date())).\(fileExtension)"
    }
}
