#!/bin/bash
# Builds a release, packages it as a DMG, and optionally publishes it to GitHub.
#
#   Scripts/make-release.sh 0.1.0           # build and package into dist/
#   Scripts/make-release.sh 0.1.0 --publish # …and create the GitHub release
#
# Signing happens here rather than in CI on purpose: the certificate is what the
# Keychain on every user's Mac trusts, so it never leaves this machine. Losing it
# — or letting it leak — is worse than losing the repository.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" || "$VERSION" == -* ]]; then
    echo "usage: $(basename "$0") <version> [--publish]   e.g. $(basename "$0") 0.1.0" >&2
    exit 1
fi
PUBLISH=false
[[ "${2:-}" == "--publish" ]] && PUBLISH=true

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/build/release"
DIST="$REPO/dist"
APP_NAME="Tessera"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
APPCAST="$DIST/appcast.xml"

cd "$REPO"

# Sparkle compares CFBundleVersion, so the appcast has to carry the same number
# the app was built with.
BUILD_NUMBER="$(git rev-list --count HEAD)"

# A release must be reproducible from a known commit, and the tag has to describe
# what is actually in the DMG.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty — commit or stash first" >&2
    exit 1
fi

echo "==> Testing the core"
TESTLOG="$(mktemp)"
if ! (cd TesseraCore && swift test) > "$TESTLOG" 2>&1; then
    echo "error: core tests failed" >&2
    tail -30 "$TESTLOG" >&2
    exit 1
fi
grep -E 'Executed [0-9]+ tests' "$TESTLOG" | tail -1 || true
rm -f "$TESTLOG"

echo "==> Building $APP_NAME $VERSION (Release)"
rm -rf "$BUILD"
xcodebuild -project Tessera.xcodeproj -scheme "$APP_NAME" \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$BUILD" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    clean build 2>&1 | grep -E '^\*\* BUILD (SUCCEEDED|FAILED)' || {
        echo "error: build failed — rerun the xcodebuild line above for detail" >&2
        exit 1
    }

APP="$BUILD/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }

# The whole point of signing is that users' Keychain permissions survive updates;
# an accidentally ad-hoc release would silently break that for everyone.
echo "==> Verifying the signature"
codesign --verify --strict --deep "$APP"
# Authority only appears at verbosity 2 and above.
SIGINFO="$(codesign -dvv "$APP" 2>&1)"
AUTHORITY="$(sed -n 's/^Authority=//p' <<<"$SIGINFO" | head -1)"
if [[ -z "$AUTHORITY" ]] || grep -q '^Signature=adhoc' <<<"$SIGINFO"; then
    cat >&2 <<'EOF'
error: the app is ad-hoc signed.

Releasing it would reset every user's Keychain permissions on update. Run
Scripts/make-signing-cert.sh to create a certificate, then build again.
EOF
    exit 1
fi
echo "    signed by: $AUTHORITY"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    requirement: /p'

echo "==> Packaging the DMG"
rm -rf "$DIST" && mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

# Sparkle refuses an update whose EdDSA signature does not match SUPublicEDKey in
# the app, so the DMG is signed here; sign_update reads the private key from this
# machine's login Keychain. The appcast travels as a release asset — SUFeedURL
# points at releases/latest/download/appcast.xml, which GitHub redirects to the
# newest release, so no separate hosting is needed.
echo "==> Signing the update and building the appcast"
SIGN_UPDATE="$(find "$BUILD/SourcePackages/artifacts" -name sign_update -type f | head -1)"
[[ -n "$SIGN_UPDATE" ]] || {
    echo "error: sign_update not found — Sparkle's artifact bundle is missing from $BUILD" >&2
    exit 1
}
# Prints a ready-made pair of attributes: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN_UPDATE" "$DMG")"

SLUG="$(git remote get-url origin | sed -E 's#^.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"
DMG_URL="https://github.com/$SLUG/releases/download/v$VERSION/$(basename "$DMG")"
PUBDATE="$(LC_TIME=C date -u +'%a, %d %b %Y %H:%M:%S +0000')"

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <link>https://github.com/$SLUG</link>
    <description>Updates for $APP_NAME.</description>
    <language>en</language>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$SLUG/releases/tag/v$VERSION</link>
      <enclosure url="$DMG_URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST"
echo "    appcast: $VERSION (build $BUILD_NUMBER) -> $DMG_URL"

echo
echo "Built $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"

if ! $PUBLISH; then
    echo "Run again with --publish to create the GitHub release."
    exit 0
fi

echo "==> Publishing v$VERSION"
git tag -a "v$VERSION" -m "Tessera $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$DMG" "$DMG.sha256" "$APPCAST" \
    --title "Tessera $VERSION" \
    --notes "$(cat <<EOF
## Installing

Download the DMG, open it, and drag Tessera to Applications.

Tessera is signed with a self-signed certificate but **not notarized**, because
notarization requires a paid Apple Developer account. macOS will refuse to open it
on first launch. Dismiss the warning, then go to **System Settings ▸ Privacy &
Security** and click **Open Anyway**.

Alternatively: \`xattr -dr com.apple.quarantine /Applications/Tessera.app\`

You only have to do this once: later versions arrive through the built-in updater,
which verifies the signature of each update before installing it.

Requires macOS 26 or later.
EOF
)"
echo "Done: $(gh release view "v$VERSION" --json url --jq .url)"

# The Homebrew tap is a second, tiny repository (tedyno/homebrew-tessera), because
# brew only recognises taps whose name carries the homebrew- prefix. The cask is
# regenerated from scratch every time rather than patched in place, so it cannot
# drift out of sync with the release.
TAP_DIR="${TESSERA_TAP_DIR:-$REPO/../homebrew-tessera}"
if [[ ! -d "$TAP_DIR/.git" ]]; then
    echo "warning: no Homebrew tap checkout at $TAP_DIR — cask not updated" >&2
    exit 0
fi

echo "==> Updating the Homebrew cask"
SHA256="$(cut -d' ' -f1 < "$DMG.sha256")"
mkdir -p "$TAP_DIR/Casks"
# auto_updates leaves upgrades to Sparkle: brew skips such casks in `brew upgrade`,
# so the two updaters never fight over the same app.
cat > "$TAP_DIR/Casks/tessera.rb" <<RUBY
cask "tessera" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$SLUG/releases/download/v#{version}/$APP_NAME-#{version}.dmg"
  name "$APP_NAME"
  desc "Native database client for PostgreSQL, MySQL, MariaDB and SQLite"
  homepage "https://github.com/$SLUG"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe

  app "$APP_NAME.app"

  zap trash: [
    "~/Library/Application Support/io.github.tedyno.tessera",
    "~/Library/Caches/io.github.tedyno.tessera",
    "~/Library/Preferences/io.github.tedyno.tessera.plist",
    "~/Library/Saved Application State/io.github.tedyno.tessera.savedState",
  ]
end
RUBY

git -C "$TAP_DIR" add Casks/tessera.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "    cask already up to date"
else
    git -C "$TAP_DIR" commit -qm "Tessera $VERSION"
    git -C "$TAP_DIR" push -q && echo "    cask published: brew install --cask tessera"
fi
