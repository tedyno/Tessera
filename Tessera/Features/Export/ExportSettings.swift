import SwiftUI
import AppKit

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

    /// A canonical, timestamped file name, e.g. `shop_2026-07-19_1342.sql`.
    static func fileName(base: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let safe = base.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return "\(String(safe))_\(formatter.string(from: Date())).sql"
    }
}

/// The app's Settings window (⌘,) — currently the default export folder.
struct ExportSettingsView: View {
    @State private var directory = ExportSettings.directory

    var body: some View {
        Form {
            Section("Export") {
                LabeledContent("Default folder") {
                    HStack(spacing: 8) {
                        Text(directory.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                        Button("Downloads") { reset() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            ExportSettings.setDirectory(url)
            directory = url
        }
    }

    private func reset() {
        ExportSettings.resetDirectory()
        directory = ExportSettings.directory
    }
}
