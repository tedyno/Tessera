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

    /// The 9 mesh control-point colours for the given scheme, derived from the
    /// scheme's base + accent. `.none` returns an empty array (callers must not
    /// build a mesh from it).
    func meshColors(for scheme: ColorScheme) -> [Color] {
        let dark = scheme == .dark
        switch self {
        case .monokai:
            return Self.palette(darkBase: (0.176, 0.165, 0.180),
                                lightBase: (0.992, 0.976, 0.953),
                                accent: (1.00, 0.38, 0.53), dark: dark)   // pink
        case .machine:
            return Self.palette(darkBase: (0.114, 0.145, 0.157),
                                lightBase: (0.933, 0.957, 0.953),
                                accent: (0.47, 0.86, 0.91), dark: dark)   // teal
        case .octagon:
            return Self.palette(darkBase: (0.157, 0.165, 0.227),
                                lightBase: (0.933, 0.937, 0.969),
                                accent: (0.67, 0.62, 0.95), dark: dark)   // lavender
        case .ristretto:
            return Self.palette(darkBase: (0.173, 0.145, 0.145),
                                lightBase: (0.969, 0.945, 0.933),
                                accent: (0.95, 0.55, 0.44), dark: dark)   // coral
        case .spectrum:
            return Self.palette(darkBase: (0.133, 0.133, 0.133),
                                lightBase: (0.961, 0.961, 0.961),
                                accent: (0.69, 0.69, 0.75), dark: dark)   // neutral
        case .catppuccin:
            return Self.palette(darkBase: (0.118, 0.118, 0.180),   // Mocha  #1E1E2E
                                lightBase: (0.937, 0.945, 0.961),   // Latte  #EFF1F5
                                accent: (0.80, 0.65, 0.97), dark: dark)   // mauve
        case .tokyoNight:
            return Self.palette(darkBase: (0.102, 0.106, 0.149),   // #1A1B26
                                lightBase: (0.882, 0.886, 0.906),   // Day    #E1E2E7
                                accent: (0.48, 0.64, 0.97), dark: dark)   // azure
        case .dracula:
            return Self.palette(darkBase: (0.157, 0.165, 0.212),   // #282A36
                                lightBase: (0.973, 0.973, 0.949),   // Alucard
                                accent: (0.74, 0.58, 0.98), dark: dark)   // violet
        case .nord:
            return Self.palette(darkBase: (0.180, 0.204, 0.251),   // #2E3440
                                lightBase: (0.925, 0.937, 0.957),   // #ECEFF4
                                accent: (0.53, 0.75, 0.82), dark: dark)   // frost
        case .gruvbox:
            return Self.palette(darkBase: (0.157, 0.157, 0.157),   // #282828
                                lightBase: (0.984, 0.945, 0.780),   // #FBF1C7
                                accent: (1.00, 0.50, 0.10), dark: dark)   // orange
        case .rosePine:
            return Self.palette(darkBase: (0.098, 0.090, 0.141),   // #191724
                                lightBase: (0.980, 0.957, 0.929),   // Dawn   #FAF4ED
                                accent: (0.77, 0.65, 0.91), dark: dark)   // iris
        case .oneDark:
            return Self.palette(darkBase: (0.157, 0.173, 0.204),   // #282C34
                                lightBase: (0.980, 0.980, 0.980),   // One Light
                                accent: (0.38, 0.69, 0.94), dark: dark)   // blue
        case .none:
            return []
        }
    }

    /// Solid fill used when `.none` needs a concrete colour (offscreen export).
    func solidFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.09, green: 0.10, blue: 0.13)
                        : Color(red: 0.95, green: 0.96, blue: 0.98)
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
