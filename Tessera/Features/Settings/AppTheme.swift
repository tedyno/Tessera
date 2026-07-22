import SwiftUI

/// The app's colour scheme override. `system` follows macOS; the others pin the
/// window light or dark. Raw values back the `tessera.appearance.theme`
/// @AppStorage preference and take effect live via `.preferredColorScheme`.
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

    /// The scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static let key = "tessera.appearance.theme"
}
