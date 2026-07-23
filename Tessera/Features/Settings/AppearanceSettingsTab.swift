import SwiftUI

/// Appearance preferences. Every control writes the same `@AppStorage` key the
/// feature already reads (theme, window backdrop, diagram edge/background styles,
/// results row density), so the live UI updates immediately and the inline
/// selectors elsewhere stay in sync — this tab is just a second home for them.
struct AppearanceSettingsTab: View {
    @AppStorage(AppTheme.key) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(BackdropStyle.key) private var backdropRaw = BackdropStyle.monokai.rawValue
    @AppStorage("tessera.diagram.edgeStyle") private var edgeStyleRaw = DiagramEdgeStyle.curved.rawValue
    @AppStorage("tessera.diagram.background") private var backgroundRaw = DiagramBackgroundStyle.plain.rawValue
    /// Grid row density; compact matches a terminal, comfortable breathes.
    @AppStorage("tessera.gridDensity") private var gridComfortable = false

    var body: some View {
        Form {
            Section("Window") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                // A swatch grid rather than a dropdown, so the actual gradient of
                // each theme is visible before it's chosen.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Window backdrop")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 10)],
                              alignment: .leading, spacing: 12) {
                        ForEach(BackdropStyle.allCases) { style in
                            BackdropSwatch(style: style, selected: style.rawValue == backdropRaw)
                                .onTapGesture { backdropRaw = style.rawValue }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Section("Diagram") {
                Picker("Diagram edges", selection: $edgeStyleRaw) {
                    Text("Curved").tag(DiagramEdgeStyle.curved.rawValue)
                    Text("Right-angled").tag(DiagramEdgeStyle.orthogonal.rawValue)
                }
                Picker("Canvas background", selection: $backgroundRaw) {
                    Text("Plain").tag(DiagramBackgroundStyle.plain.rawValue)
                    Text("Dots").tag(DiagramBackgroundStyle.dots.rawValue)
                    Text("Grid").tag(DiagramBackgroundStyle.grid.rawValue)
                }
            }
            Section("Results grid") {
                Picker("Row density", selection: $gridComfortable) {
                    Text("Comfortable").tag(true)
                    Text("Compact").tag(false)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// One selectable backdrop tile: a rounded preview of the theme's gradient (in the
/// current light/dark), its name below, and a check when it's the active choice.
private struct BackdropSwatch: View {
    let style: BackdropStyle
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: selected ? 2 : 1)
                    }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(height: 46)
            Text(style.title)
                .font(.caption2)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(style.title)
    }

    @ViewBuilder
    private var preview: some View {
        if style == .none {
            // No gradient — show the frosted surface it falls back to.
            Rectangle().fill(.regularMaterial)
        } else {
            MeshGradient(width: 3, height: 3,
                         points: TesseraBackdrop.meshPoints,
                         colors: style.meshColors(for: scheme))
        }
    }
}
