import Foundation

/// Which on-disk (and Keychain) namespace this build owns.
///
/// Every store — profiles, organizer, history, saved queries, schema cache,
/// secrets — hangs off this one identifier, so a build can only ever touch its
/// own data. The Debug configuration has its own bundle id
/// (`io.github.tedyno.tessera.dev`), which is what keeps a development build
/// away from the connections you actually work with.
///
/// That bundle id is not enough on its own. A build made before the ids were
/// split still carries the release identifier, and running one out of DerivedData
/// points it straight at the installed app's files — which is how 33 of 34 saved
/// connections were once destroyed. So the identifier is checked against *where
/// the app is running from* as well: anything running out of a build directory is
/// pushed into the development namespace no matter what its Info.plist claims.
///
/// The test is deliberately "is this a build product?" rather than "is this in
/// /Applications?". People legitimately run the app from `~/Applications`, or
/// straight off a mounted DMG before dragging it across; sending those to a
/// different namespace would show them an empty connection list, which is the
/// very failure this is meant to prevent.
///
/// The fallback is only for hosts without a bundle identifier (unit tests,
/// command-line tools); those pass explicit file URLs anyway.
public enum StorageIdentity {
    public static let releaseBundleID = "io.github.tedyno.tessera"

    /// Marks the namespace a development build gets. Already-suffixed ids are left
    /// alone rather than doubled up.
    public static let developmentSuffix = ".dev"

    /// The running build's storage namespace.
    public static var current: String {
        namespace(bundleID: Bundle.main.bundleIdentifier,
                  bundlePath: Bundle.main.bundleURL.path)
    }

    /// True when this build is running from a build directory rather than an
    /// installed copy — and is therefore not allowed near the release store.
    public static var isDevelopmentBuild: Bool {
        current.hasSuffix(developmentSuffix)
    }

    /// Pure form, so the rule can be tested without an app bundle.
    static func namespace(bundleID: String?, bundlePath: String) -> String {
        let id = bundleID ?? releaseBundleID
        guard isBuildProduct(path: bundlePath), !id.hasSuffix(developmentSuffix) else { return id }
        return id + developmentSuffix
    }

    /// Xcode writes products under DerivedData; `xcodebuild -derivedDataPath` and
    /// SwiftPM put them somewhere else entirely, but always under `Build/Products`.
    /// Both spellings are checked so a custom derived-data path is covered too.
    static func isBuildProduct(path: String) -> Bool {
        path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }
}
