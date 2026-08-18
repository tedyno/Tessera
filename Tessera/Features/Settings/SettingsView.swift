import SwiftUI
import AppKit

/// The app's Settings window (⌘,), split into tabs. Each tab is a self-contained
/// `Form`; persistence stays in the per-feature stores (`ExportSettings`,
/// `MCPSettings`, `AppLanguage`) and `@AppStorage` keys — there is no shared
/// settings model to keep in sync.
///
/// The whole window carries the theme's gradient as one continuous wash. The
/// window is switched to `fullSizeContentView` with a transparent titlebar, so the
/// edge-to-edge backdrop paints behind the tab strip too and the tabs float on it —
/// no seam between a solid header and a gradient body. The toolbar still reserves
/// its safe-area height, so form rows scroll up to just under the tabs, not behind
/// them.
/// Which tab the Settings window shows. `pending` lets a caller elsewhere in the
/// app aim the window before opening it (see `SettingsTab.open(_:)`).
enum SettingsTab: Hashable {
    case general, appearance, export, mcp

    @MainActor private(set) static var pending: SettingsTab?

    /// Asks for Settings to show `tab`. The pending value covers a window that is
    /// about to be created; the notification retargets one that is already open.
    @MainActor static func request(_ tab: SettingsTab) {
        pending = tab
        NotificationCenter.default.post(name: .openSettingsTab, object: nil)
    }

    @MainActor static func takePending() -> SettingsTab? {
        defer { pending = nil }
        return pending
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("tessera.settings.openTab")
}

struct SettingsView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            ExportSettingsTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(SettingsTab.export)
            MCPSettingsTab()
                .tabItem { Label("MCP", systemImage: "network") }
                .tag(SettingsTab.mcp)
        }
        .onAppear { if let requested = SettingsTab.takePending() { tab = requested } }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { _ in
            if let requested = SettingsTab.takePending() { tab = requested }
        }
        // Fixed size: the tallest tab (Appearance, with the backdrop grid) drives
        // the height. Native Settings windows keep a stable width per tab.
        .frame(width: 560, height: 620)
        .background { TesseraBackdrop(frosted: false) }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(SettingsWindowConfigurator())
    }
}

/// Switches the Settings `NSWindow` to a full-size content view with a transparent
/// titlebar, so the SwiftUI backdrop can paint edge to edge behind the tab strip.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var configured = false }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in configure(view?.window, coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window, context.coordinator)
    }

    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Let the window own its position like any macOS window: the system places
        // it on first open and restores it thereafter via this autosave name. No
        // manual centering — that would visibly hop the window after it's already
        // on screen. Set once, so re-restoring the frame doesn't fight the user.
        guard !coordinator.configured else { return }
        coordinator.configured = true
        _ = window.setFrameAutosaveName("TesseraSettings")
    }
}
