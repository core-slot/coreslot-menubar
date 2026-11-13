#!/usr/bin/env bash
# Signs, notarises and staples one release on the release Mac, and prints the zip's sha256.
#
#   scripts/release.sh VERSION        (VERSION is X.Y.Z or X.Y.Z-PRE; the tag vVERSION is at HEAD)
#
# The Developer ID identity and the notary profile coreslot-notary are read from the signing
# keychain alone; the owner unlocks it once after each reboot. Nothing here pushes or publishes.
# The result is build/coreslot-menubar-VERSION.zip, which holds the stapled coreslot.app.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 VERSION" >&2
    exit 64
fi
version="$1"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "VERSION must be X.Y.Z or X.Y.Z-PRE, got: $version" >&2
    exit 64
fi

keychain="$HOME/Library/Keychains/coreslot-signing.keychain-db"
profile="coreslot-notary"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ -n "$(git status --porcelain)" ]; then
    echo "the working tree is not clean; release from a clean checkout" >&2
    git status --short >&2
    exit 65
fi
head="$(git rev-parse HEAD)"
tagged="$(git rev-parse -q --verify "refs/tags/v$version^{commit}" || true)"
if [ "$tagged" != "$head" ]; then
    echo "the tag v$version is not at HEAD ($head); tag the commit to release first" >&2
    exit 65
fi

scripts/bundle.sh --identity "Developer ID Application" --keychain "$keychain" --version "$version"

app="build/coreslot.app"
zip="build/coreslot-menubar-$version.zip"
upload="build/notarise-$version.zip"
result="build/notarise-$version.json"
rm -f "$zip" "$upload" "$result"

ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$upload"
# The submission's status decides, whatever notarytool's exit code; without an id nothing was sent.
xcrun notarytool submit "$upload" --keychain-profile "$profile" --keychain "$keychain" \
    --wait --output-format json >"$result" || true
if ! id="$(plutil -extract id raw -o - "$result" 2>/dev/null)"; then
    echo "notarytool returned no submission id" >&2
    cat "$result" >&2
    exit 1
fi
status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
echo "notarisation $id: $status"
if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" --keychain "$keychain" >&2 || true
    exit 1
fi
rm -f "$upload"

xcrun stapler staple "$app"
xcrun stapler validate "$app"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$zip"
spctl --assess --type execute -v "$app"
shasum -a 256 "$zip"
