import SwiftUI
import AppKit

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
        // Hide the tab strip's material so the backdrop runs continuously from the
        // tabs into the content — no grey toolbar seam.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // frosted: false — a titled window can't show the behind-window frost
        // cleanly, so the gradient fills it uniformly. `.none` draws nothing here
        // and keeps the native window surface.
        .background { TesseraBackdrop(frosted: false).ignoresSafeArea() }
        // Extend the content (and its gradient) under the transparent titlebar, so
        // hiding the toolbar material shows the gradient there — not the desktop.
        .background(SettingsWindowStyler())
    }
}

/// Configures the Settings NSWindow so the gradient can fill edge to edge: a
/// transparent titlebar over full-size content. Without this, hiding the toolbar
/// material leaves the titlebar clear and the desktop shows through the top.
private struct SettingsWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
