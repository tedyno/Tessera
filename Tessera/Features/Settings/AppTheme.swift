import SwiftUI
import AppKit

/// The app's colour scheme override. `system` follows macOS; the others pin the
/// app light or dark. Raw values back the `tessera.appearance.theme` @AppStorage
/// preference.
///
/// Applied app-wide via `NSApp.appearance` rather than per-scene
/// `.preferredColorScheme`: the latter left titlebars and content out of sync
/// when switching back to System, whereas the application appearance drives every
/// window (and its titlebar) uniformly, and `nil` cleanly restores the system.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The AppKit appearance to force, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static let key = "tessera.appearance.theme"

    /// The persisted choice.
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Pins (or clears) the whole application's appearance to match the stored theme.
    static func applyToApp() {
        NSApplication.shared.appearance = current.nsAppearance
    }
}
