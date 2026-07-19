import Foundation
import AppKit

/// The interface language. `system` follows macOS; the others pin the app by
/// writing `AppleLanguages` into its own defaults, which macOS reads at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case czech = "cs"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .czech: "Čeština"
        }
    }

    private static let key = "AppleLanguages"

    /// The language currently pinned in this app's defaults, if any.
    static var current: AppLanguage {
        guard let codes = UserDefaults.standard.array(forKey: key) as? [String],
              let first = codes.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// Pins (or clears) the language. Takes effect on the next launch, because the
    /// bundle resolves its localization once at startup.
    static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Restarts the app so the new language is picked up.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
