#!/bin/bash
# Creates a self-signed code signing certificate and points local builds at it.
#
# Why: ad-hoc signing gives the app a different identity on every build, so the
# Keychain sees each build as a different application and asks permission again
# for every stored password. A stable certificate makes that stop — for you while
# developing, and for users across app updates.
#
# This does NOT get you past Gatekeeper; that needs a paid Developer ID and
# notarization. It only gives the app a stable identity.
set -euo pipefail

NAME="${1:-Tessera Self-Signed}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# LibreSSL (the system openssl) cannot add v3 extensions here; prefer Homebrew's.
OPENSSL=openssl
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    [ -x "$candidate" ] && OPENSSL="$candidate" && break
done
if ! "$OPENSSL" version | grep -q '^OpenSSL'; then
    echo "error: OpenSSL 3 is required (brew install openssl@3)" >&2
    exit 1
fi

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "Certificate “${NAME}” already exists — nothing to do."
    exit 0
fi

echo "Generating “${NAME}” (valid 20 years)…"
"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 7300 -nodes -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -passout pass:temp -name "$NAME" -legacy 2>/dev/null

security import "$WORK/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P temp -T /usr/bin/codesign >/dev/null

# A self-signed certificate has to be trusted as its own root before codesign
# will accept it. This prompts for your password.
echo "Trusting the certificate (macOS will ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$WORK/cert.pem"

mkdir -p "$REPO/Config"
if [ ! -f "$REPO/Config/Local.xcconfig" ]; then
    {
        printf 'CODE_SIGN_IDENTITY = %s\n' "$NAME"
        # Automatic signing insists on a development team; a self-signed
        # certificate needs manual signing instead.
        printf 'CODE_SIGN_STYLE = Manual\n'
    } > "$REPO/Config/Local.xcconfig"
    echo "Wrote Config/Local.xcconfig."
fi

security find-identity -v -p codesigning | grep -F "$NAME" || {
    echo "warning: the certificate is not showing up as valid yet" >&2
    exit 1
}
echo "Done. Xcode builds will now be signed with “${NAME}”."
