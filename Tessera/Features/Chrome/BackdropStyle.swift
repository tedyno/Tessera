import SwiftUI

/// A choice of window backdrop. Each style supplies a 9-colour mesh palette for
/// light and dark; `.none` skips the gradient and shows only the frosted
/// behind-window blur. Raw values back the `tessera.appearance.backdrop`
/// @AppStorage preference.
///
/// The set is drawn from the most-loved editor colour schemes — the Monokai Pro
/// filter family plus Catppuccin, Tokyo Night, Dracula, Nord, Gruvbox, Rosé Pine
/// and One Dark. Each is hand-seeded from that scheme's real base and accent, and
/// rendered as one gentle wash with a faint accent glow in two corners, never a
/// saturated mesh.
enum BackdropStyle: String, CaseIterable, Identifiable {
    case monokai    // Monokai Pro (Classic) — warm aubergine, pink accent
    case machine    // Monokai Pro Machine — cool teal-grey, teal accent
    case octagon    // Monokai Pro Octagon — indigo, lavender accent
    case ristretto  // Monokai Pro Ristretto — warm coffee, coral accent
    case spectrum   // Monokai Pro Spectrum — near-neutral dark
    case catppuccin // Catppuccin Mocha / Latte — soft pastel, mauve accent
    case tokyoNight // Tokyo Night — deep blue, azure accent
    case dracula    // Dracula — navy-purple, violet accent
    case nord       // Nord — cold slate, frost accent
    case gruvbox    // Gruvbox — warm, orange accent
    case rosePine   // Rosé Pine — muted plum, iris accent
    case oneDark    // One Dark — balanced grey, blue accent
    case none       // no gradient, just the frosted blur

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .monokai: "Monokai"
        case .machine: "Machine"
        case .octagon: "Octagon"
        case .ristretto: "Ristretto"
        case .spectrum: "Spectrum"
        case .catppuccin: "Catppuccin"
        case .tokyoNight: "Tokyo Night"
        case .dracula: "Dracula"
        case .nord: "Nord"
        case .gruvbox: "Gruvbox"
        case .rosePine: "Rosé Pine"
        case .oneDark: "One Dark"
        case .none: "None"
        }
    }

    /// The persisted choice, readable outside the SwiftUI environment (the
    /// offscreen diagram export path).
    static var current: BackdropStyle {
        BackdropStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .monokai
    }

    static let key = "tessera.appearance.backdrop"

    /// The style's base colours (dark, light) plus its accent glow. `.none` has
    /// no gradient seed and falls back to a neutral pair.
    private typealias RGB = (Double, Double, Double)
    private var seed: (dark: RGB, light: RGB, accent: RGB) {
        switch self {
        case .monokai:   return ((0.176, 0.165, 0.180), (0.992, 0.976, 0.953), (1.00, 0.38, 0.53)) // pink
        case .machine:   return ((0.114, 0.145, 0.157), (0.933, 0.957, 0.953), (0.47, 0.86, 0.91)) // teal
        case .octagon:   return ((0.157, 0.165, 0.227), (0.933, 0.937, 0.969), (0.67, 0.62, 0.95)) // lavender
        case .ristretto: return ((0.173, 0.145, 0.145), (0.969, 0.945, 0.933), (0.95, 0.55, 0.44)) // coral
        case .spectrum:  return ((0.133, 0.133, 0.133), (0.961, 0.961, 0.961), (0.69, 0.69, 0.75)) // neutral
        case .catppuccin: return ((0.118, 0.118, 0.180), (0.937, 0.945, 0.961), (0.80, 0.65, 0.97)) // mauve
        case .tokyoNight: return ((0.102, 0.106, 0.149), (0.882, 0.886, 0.906), (0.48, 0.64, 0.97)) // azure
        case .dracula:   return ((0.157, 0.165, 0.212), (0.973, 0.973, 0.949), (0.74, 0.58, 0.98)) // violet
        case .nord:      return ((0.180, 0.204, 0.251), (0.925, 0.937, 0.957), (0.53, 0.75, 0.82)) // frost
        case .gruvbox:   return ((0.157, 0.157, 0.157), (0.984, 0.945, 0.780), (1.00, 0.50, 0.10)) // orange
        case .rosePine:  return ((0.098, 0.090, 0.141), (0.980, 0.957, 0.929), (0.77, 0.65, 0.91)) // iris
        case .oneDark:   return ((0.157, 0.173, 0.204), (0.980, 0.980, 0.980), (0.38, 0.69, 0.94)) // blue
        case .none:      return ((0.090, 0.100, 0.130), (0.950, 0.960, 0.980), (0.69, 0.69, 0.75)) // neutral
        }
    }

    /// The 9 mesh control-point colours for the given scheme, derived from the
    /// scheme's base + accent. `.none` returns an empty array (callers must not
    /// build a mesh from it).
    func meshColors(for scheme: ColorScheme) -> [Color] {
        guard self != .none else { return [] }
        let s = seed
        return Self.palette(darkBase: s.dark, lightBase: s.light, accent: s.accent,
                            dark: scheme == .dark)
    }

    /// The representative base colour for the scheme — used by AppKit surfaces
    /// (the results-grid header) that must sit on the backdrop without a system
    /// bezel, so they track whichever theme is chosen.
    func baseColor(for scheme: ColorScheme) -> Color {
        let base = scheme == .dark ? seed.dark : seed.light
        return Color(red: base.0, green: base.1, blue: base.2)
    }

    /// Tint for a floating glass card so it carries the theme's hue instead of a
    /// flat neutral grey, while still standing off the backdrop: darker than the
    /// gradient in dark mode, brighter (toward white) in light mode.
    func panelTint(for scheme: ColorScheme) -> Color {
        let base = scheme == .dark ? seed.dark : seed.light
        if scheme == .dark {
            return Color(red: base.0 * 0.5, green: base.1 * 0.5, blue: base.2 * 0.5)
        } else {
            func lighten(_ c: Double) -> Double { c + (1 - c) * 0.5 }
            return Color(red: lighten(base.0), green: lighten(base.1), blue: lighten(base.2))
        }
    }

    /// Solid fill used when `.none` needs a concrete colour (offscreen export).
    func solidFill(for scheme: ColorScheme) -> Color {
        baseColor(for: scheme)
    }

    // MARK: Palette generation

    /// Builds a subtle 9-point mesh from a base colour plus a faint accent glow
    /// in two opposite corners. Dark mode brightens the corners for a soft light
    /// bloom; light mode stays airy. Intentionally gentle — no garish mesh.
    private static func palette(darkBase: (Double, Double, Double),
                                lightBase: (Double, Double, Double),
                                accent: (Double, Double, Double),
                                dark: Bool) -> [Color] {
        let base = dark ? darkBase : lightBase
        // Per-cell brightness scale and accent mix (row-major).
        let bright: [Double] = dark
            ? [1.14, 1.02, 1.10, 1.00, 0.94, 1.00, 1.06, 1.02, 1.18]
            : [1.00, 1.00, 0.995, 1.00, 1.00, 0.99, 0.995, 1.00, 0.985]
        let tint: [Double] = dark
            ? [0.10, 0.0, 0.05, 0.0, 0.0, 0.0, 0.04, 0.0, 0.12]
            : [0.06, 0.0, 0.03, 0.0, 0.0, 0.0, 0.02, 0.0, 0.07]
        func channel(_ b: Double, _ a: Double, scale: Double, mix: Double) -> Double {
            min(max((b + (a - b) * mix) * scale, 0), 1)
        }
        return zip(bright, tint).map { scale, mix in
            Color(red: channel(base.0, accent.0, scale: scale, mix: mix),
                  green: channel(base.1, accent.1, scale: scale, mix: mix),
                  blue: channel(base.2, accent.2, scale: scale, mix: mix))
        }
    }
}
