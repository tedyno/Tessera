import SwiftUI

/// The app's Settings window (⌘,), split into tabs. Each tab is a self-contained
/// `Form`; persistence stays in the per-feature stores (`ExportSettings`,
/// `MCPSettings`, `AppLanguage`) and `@AppStorage` keys — there is no shared
/// settings model to keep in sync.
///
/// The window wears the same gradient backdrop as the main window (each tab's
/// form background is hidden so it glows through), so Settings matches the app.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            ExportSettingsTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            MCPSettingsTab()
                .tabItem { Label("MCP", systemImage: "network") }
        }
        // Fixed size: the tallest tab (MCP, expanded) drives the height. Native
        // Settings windows keep a stable width, so each tab lays out at 500 pt.
        .frame(width: 500, height: 460)
        // Hide the tab strip's own material so the backdrop runs continuously
        // from the tabs into the content — otherwise a hard seam shows under them.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // frosted: false — a titled window can't show the behind-window frost
        // cleanly, so the gradient fills it uniformly. `.none` draws nothing here
        // and keeps the native window surface.
        .background { TesseraBackdrop(frosted: false).ignoresSafeArea() }
    }
}
