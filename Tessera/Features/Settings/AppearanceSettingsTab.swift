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
                Picker("Window backdrop", selection: $backdropRaw) {
                    ForEach(BackdropStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
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
