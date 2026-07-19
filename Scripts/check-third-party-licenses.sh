#!/bin/bash
# Fails if a dependency is missing from THIRD-PARTY-LICENSES.md.
#
# Attribution is a licence obligation, not documentation: MIT and Apache-2.0 both
# require us to ship their notices. A dependency added without updating that file
# puts the project out of compliance silently, so CI checks it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTICES="$REPO/THIRD-PARTY-LICENSES.md"
RESOLVED="$REPO/TesseraCore/Package.resolved"

missing=()
while read -r identity; do
    grep -qF "$identity" "$NOTICES" || missing+=("$identity")
done < <(python3 -c "
import json
for pin in json.load(open('$RESOLVED'))['pins']:
    print(pin['identity'])")

if [ ${#missing[@]} -gt 0 ]; then
    echo "error: not attributed in THIRD-PARTY-LICENSES.md:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
fi
echo "All $(python3 -c "
import json; print(len(json.load(open('$RESOLVED'))['pins']))") dependencies are attributed."
