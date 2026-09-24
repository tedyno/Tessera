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

        // Persisting the resting icon writes an `Icon\r` + Finder-info override onto
        // the .app. That's fine for a shipped, already-signed build, but codesign
        // refuses to *re-sign* a bundle carrying that detritus — which would break
        // every incremental dev build. So only Release builds (the ones users
        // actually install and never re-sign) persist it; Debug keeps the live Dock
        // icon only.
#if !DEBUG
        // Writing to disk, so skip it when nothing changed (launch applies once,
        // then only on real theme/appearance flips).
        guard key != lastAppliedKey else { return }
        lastAppliedKey = key
        // `nil` clears the override; anything else has to arrive as a full icon
        // family (see `iconFamily(from:)`).
        let resting = image.map(iconFamily(from:))
        let written = NSWorkspace.shared.setIcon(resting, forFile: Bundle.main.bundlePath,
                                                 options: [])
        if !written {
            // The result used to be discarded, so the resting icon quietly not
            // persisting looked like nothing had happened at all. Say so, and
            // let the next launch try again rather than believing it's done.
            NSLog("ThemeIcon: could not write the resting icon for \(key)")
            lastAppliedKey = nil
        }
#endif
    }

#if !DEBUG
    /// The sizes an `.icns` actually stores, in points; each is also rendered at
    /// @2x.
    private static let iconSizes: [CGFloat] = [16, 32, 128, 256, 512]

    /// Rebuilds the artwork as a multi-representation image.
    ///
    /// The theme icons ship as a single 1024×1024 PNG. Handed straight to
    /// `NSWorkspace.setIcon`, IconServices has to derive a whole `.icns` family
    /// from that one representation, and its `addCGImage:scale:` fails — it logs
    /// an `os_log` fault, which macOS escalates into killing the process. The
    /// resting icon was therefore never written, which is also why a themed icon
    /// never survived quitting the app.
    private static func iconFamily(from image: NSImage) -> NSImage {
        let family = NSImage(size: NSSize(width: 512, height: 512))
        for points in iconSizes {
            for scale in [1, 2] where !(points == 512 && scale == 2) {
                if let rep = representation(of: image, points: points, scale: scale) {
                    family.addRepresentation(rep)
                }
            }
        }
        // If not one size rendered, the original is still better than nothing —
        // and `setIcon` reporting failure is better than handing over an empty
        // image.
        return family.representations.isEmpty ? image : family
    }

    /// One bitmap of the artwork: `points` logical size at `scale` pixels each.
    private static func representation(of image: NSImage,
                                       points: CGFloat, scale: Int) -> NSBitmapImageRep? {
        let pixels = Int(points) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Logical size drives the scale factor IconServices reads off the rep.
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points),
                   from: .zero, operation: .copy, fraction: 1)
        return rep
    }
#endif

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
#if !DEBUG
    /// The last resting-icon key written to disk, to avoid redundant `setIcon`s.
    nonisolated(unsafe) private static var lastAppliedKey: String?
#endif
}
