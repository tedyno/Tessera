import Foundation

/// Which on-disk (and Keychain) namespace this build owns.
///
/// Every store — profiles, organizer, history, saved queries, schema cache,
/// secrets — hangs off this one identifier, so a build can only ever touch its
/// own data. The Debug configuration has its own bundle id
/// (`io.github.tedyno.tessera.dev`), which is what keeps a development build
/// away from the connections you actually work with: running one must never be
/// able to read, seed or overwrite the released app's files.
///
/// The fallback is only for hosts without a bundle identifier (unit tests,
/// command-line tools); those pass explicit file URLs anyway.
public enum StorageIdentity {
    public static let releaseBundleID = "io.github.tedyno.tessera"

    /// The running build's bundle identifier.
    public static var current: String {
        Bundle.main.bundleIdentifier ?? releaseBundleID
    }
}
