import AppKit

/// Swaps the Dock icon to match the chosen backdrop theme and the effective
/// light/dark appearance. `.none` restores the bundle icon. This only affects the
/// running Dock icon (the `.app` file icon stays the bundle's), so it's reapplied
/// on launch and whenever the theme, backdrop, or system appearance changes.
enum ThemeIcon {
    static func apply() {
        let style = BackdropStyle.current
        guard style != .none else {
            NSApplication.shared.applicationIconImage = nil   // back to the bundle icon
            return
        }
        let mode = isDark ? "dark" : "light"
        NSApplication.shared.applicationIconImage = NSImage(named: "icon-\(style.rawValue)-\(mode)")
    }

    /// The mode the icon should use: the explicit theme override, or the live
    /// system appearance when following it.
    private static var isDark: Bool {
        switch AppTheme.current {
        case .light: false
        case .dark: true
        case .system:
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// Re-applies the icon when the system flips light/dark while the theme follows
    /// the system. Idempotent — safe to call more than once.
    static func startObservingSystemAppearance() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            // The effective appearance lags the notification by a hair.
            DispatchQueue.main.async { apply() }
        }
    }

    nonisolated(unsafe) private static var observer: NSObjectProtocol?
}
