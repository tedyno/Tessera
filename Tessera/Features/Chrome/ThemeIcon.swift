import AppKit

/// Swaps the Dock icon to match the chosen backdrop theme and the effective
/// light/dark appearance. `.none` restores the bundle icon.
///
/// Two layers: `applicationIconImage` changes the icon of the *running* app, and
/// `NSWorkspace.setIcon` writes a custom-icon override onto the `.app` file so the
/// themed mark also shows at rest — in Finder, Launchpad, and the Dock when the app
/// is quit. That override lives in the file's resource fork, outside the signed
/// `Contents/`, so it does **not** invalidate the code signature (nor the stable
/// Keychain identity that signature anchors). Reapplied on launch and whenever the
/// theme, backdrop, or system appearance changes.
enum ThemeIcon {
    static func apply() {
        let style = BackdropStyle.current
        let key: String
        let image: NSImage?
        if style == .none {
            key = "none"
            image = nil   // nil restores the bundle's AppIcon on both layers
        } else {
            let mode = isDark ? "dark" : "light"
            key = "\(style.rawValue)-\(mode)"
            image = NSImage(named: "icon-\(key)")
        }
        NSApplication.shared.applicationIconImage = image

        // Persisting the resting icon writes to disk, so skip it when nothing
        // changed (launch always applies once, then only on real theme/appearance
        // flips).
        guard key != lastAppliedKey else { return }
        lastAppliedKey = key
        NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
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
    /// The last resting-icon key written to disk, to avoid redundant `setIcon`s.
    nonisolated(unsafe) private static var lastAppliedKey: String?
}
