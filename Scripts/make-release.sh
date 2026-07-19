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

cd "$REPO"

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
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
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

echo
echo "Built $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"

if ! $PUBLISH; then
    echo "Run again with --publish to create the GitHub release."
    exit 0
fi

echo "==> Publishing v$VERSION"
git tag -a "v$VERSION" -m "Tessera $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$DMG" "$DMG.sha256" \
    --title "Tessera $VERSION" \
    --notes "$(cat <<EOF
## Installing

Download the DMG, open it, and drag Tessera to Applications.

Tessera is signed with a self-signed certificate but **not notarized**, because
notarization requires a paid Apple Developer account. macOS will refuse to open it
on first launch. Dismiss the warning, then go to **System Settings ▸ Privacy &
Security** and click **Open Anyway**.

Alternatively: \`xattr -dr com.apple.quarantine /Applications/Tessera.app\`

Requires macOS 26 or later.
EOF
)"
echo "Done: $(gh release view "v$VERSION" --json url --jq .url)"
