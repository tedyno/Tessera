import XCTest
@testable import DBKit

/// A build that reaches the released app's store can destroy connections that exist
/// nowhere else — it has happened. The bundle id alone does not prevent it, because a
/// build made before the ids were split still carries the release one.
final class StorageIdentityTests: XCTestCase {

    private let installed = "/Applications/Tessera.app"
    private let derivedData =
        "/Users/x/Library/Developer/Xcode/DerivedData/Tessera-abc/Build/Products/Debug/Tessera.app"

    func testInstalledReleaseBuildKeepsTheReleaseNamespace() {
        XCTAssertEqual(
            StorageIdentity.namespace(bundleID: "io.github.tedyno.tessera", bundlePath: installed),
            "io.github.tedyno.tessera")
    }

    /// The exact shape of the 2026-08-28 data loss: a July build carrying the release
    /// bundle id, run out of DerivedData, straight onto the real store.
    func testReleaseIdRunFromDerivedDataIsPushedIntoTheDevNamespace() {
        XCTAssertEqual(
            StorageIdentity.namespace(bundleID: "io.github.tedyno.tessera", bundlePath: derivedData),
            "io.github.tedyno.tessera.dev")
    }

    func testDevIdIsNotSuffixedTwice() {
        XCTAssertEqual(
            StorageIdentity.namespace(bundleID: "io.github.tedyno.tessera.dev", bundlePath: derivedData),
            "io.github.tedyno.tessera.dev")
    }

    /// A custom `-derivedDataPath` puts products somewhere else entirely, but always
    /// under Build/Products.
    func testCustomDerivedDataPathIsStillRecognised() {
        XCTAssertTrue(StorageIdentity.isBuildProduct(path: "/tmp/ci/Build/Products/Release/Tessera.app"))
    }

    /// Real people keep apps outside /Applications and run them off a mounted DMG
    /// before dragging them across. Redirecting those would show an empty connection
    /// list — the very failure this guard exists to prevent.
    func testOrdinaryInstallLocationsAreNotTreatedAsBuilds() {
        for path in ["/Applications/Tessera.app",
                     "/Users/x/Applications/Tessera.app",
                     "/Volumes/Tessera 0.29.0/Tessera.app",
                     "/opt/homebrew/Caskroom/tessera/0.29.0/Tessera.app"] {
            XCTAssertFalse(StorageIdentity.isBuildProduct(path: path), path)
        }
    }

    func testMissingBundleIdFallsBackToTheReleaseNamespace() {
        XCTAssertEqual(StorageIdentity.namespace(bundleID: nil, bundlePath: installed),
                       StorageIdentity.releaseBundleID)
    }
}
