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

team="TC8A8F26GT"
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
exe="$app/Contents/MacOS/coreslot-menubar"

# What the published app must not carry. nm -ap lists the debug map's OSO and SO entries; strings -
# (all bytes, unlike strings -a, which reads only the sections) also reads the symbol-name table.
oso="$(nm -ap "$exe" | grep -cE ' (OSO|SO) ' || true)"
if [ "$oso" -ne 0 ]; then
    echo "the executable still carries $oso debug-map entries (OSO/SO); refusing to release" >&2
    exit 1
fi
if strings - "$exe" | grep -q '/Users/'; then
    echo "the executable contains a /Users/ path; refusing to release" >&2
    exit 1
fi
if strings - "$exe" | grep -qE 'present-window|--answer|--ask-stop|--measure'; then
    echo "the executable contains debug hooks (present-window, --answer, --ask-stop, --measure); refusing to release" >&2
    exit 1
fi
signed_team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$signed_team" != "$team" ]; then
    echo "the app is signed by team '${signed_team:-none}', not $team; refusing to release" >&2
    exit 1
fi

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
spctl --assess --type execute -v "$app"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$zip"

# The zip is what users download: open it again and assess the app inside.
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
ditto -x -k "$zip" "$check"
spctl --assess --type execute -v "$check/coreslot.app"

shasum -a 256 "$zip"
