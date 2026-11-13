#!/usr/bin/env bash
# Builds the release executable, assembles build/coreslot.app, signs it and verifies the signature.
#
#   scripts/bundle.sh [--ad-hoc | --identity NAME --keychain PATH] [--version X.Y.Z[-PRE]]
#
# --ad-hoc (the default) signs with no identity, for local use and checks. --identity signs with
# that identity from the keychain at PATH and nowhere else, with a secure timestamp. Both sign with
# the hardened runtime. --version defaults to 0.0.0; a pre-release suffix (0.1.0-rc1) is dropped
# from the bundle's version keys, which Apple requires to be integers.
set -euo pipefail

usage() {
    echo "usage: $0 [--ad-hoc | --identity NAME --keychain PATH] [--version X.Y.Z[-PRE]]" >&2
    exit 64
}

ad_hoc=0
identity=""
keychain=""
version="0.0.0"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ad-hoc) ad_hoc=1; shift ;;
        --identity) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; identity="$2"; shift 2 ;;
        --keychain) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; keychain="$2"; shift 2 ;;
        --version) [ "$#" -ge 2 ] || usage; version="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done
if [ "$ad_hoc" -eq 1 ] && { [ -n "$identity" ] || [ -n "$keychain" ]; }; then
    echo "--ad-hoc signs with no identity; it takes neither --identity nor --keychain" >&2
    usage
fi
if { [ -n "$identity" ] && [ -z "$keychain" ]; } || { [ -z "$identity" ] && [ -n "$keychain" ]; }; then
    echo "--identity and --keychain go together" >&2
    usage
fi
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "--version must be X.Y.Z or X.Y.Z-PRE, got: $version" >&2
    exit 64
fi
# CFBundleShortVersionString is three period-separated integers and CFBundleVersion one to three;
# both get the release's X.Y.Z.
bundle_version="${version%%-*}"

if [ -n "$keychain" ]; then
    if [ ! -f "$keychain" ]; then
        echo "no keychain at $keychain" >&2
        exit 66
    fi
    keychain="$(cd "$(dirname "$keychain")" && pwd)/$(basename "$keychain")"
    # Signing from a locked keychain would ask for its password; ask the owner to unlock it instead.
    # SecKeychainGetStatus reads the lock state without unlocking or prompting.
    lock=0
    /usr/bin/python3 -I - "$keychain" <<'PY' || lock=$?
import ctypes, sys
sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
keychain = ctypes.c_void_p()
status = ctypes.c_uint32(0)
if sec.SecKeychainOpen(sys.argv[1].encode(), ctypes.byref(keychain)) != 0:
    sys.exit(2)
if sec.SecKeychainGetStatus(keychain, ctypes.byref(status)) != 0:
    sys.exit(2)
sys.exit(0 if status.value & 1 else 1)
PY
    if [ "$lock" -eq 1 ]; then
        echo "The signing keychain is locked: please run 'security unlock-keychain $keychain' once, then run this again." >&2
        exit 75
    elif [ "$lock" -ne 0 ]; then
        echo "$keychain is not a keychain this Mac can read" >&2
        exit 66
    fi
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)"

app="build/coreslot.app"
work="build/icon"
rm -rf "$app" "$work"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$work/AppIcon.iconset"
cp "$bin/coreslot-menubar" "$app/Contents/MacOS/coreslot-menubar"
# The linker leaves a debug map (OSO and SO entries) naming the build directory's object files, so
# the build machine's paths would ship. strip -S removes the debug symbol table entries; it must
# run before codesign, which seals the file's bytes.
strip -S "$app/Contents/MacOS/coreslot-menubar"

# The icon is the menu bar glyph itself: MenuBarIcon.swift compiled beside a copy of IconState's
# cases (a case added there and not here fails this compile), drawn light on a dark tile.
sed '/^import CoreslotKit$/d' Sources/CoreslotMenubar/MenuBarIcon.swift >"$work/MenuBarIcon.swift"
cat >"$work/main.swift" <<'SWIFT'
import AppKit

enum IconState { case idle, running(fill: Int), waiting(fill: Int), pressure, unavailable }

let glyph = MenuBarIcon.image(for: .running(fill: 2))
let light = NSImage(size: glyph.size, flipped: false) { rect in
    glyph.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    return true
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let unit = CGFloat(pixels) / 1024
    // The macOS icon grid: an 824-point tile centred on a 1024-point canvas.
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit).fill()
    light.draw(in: tile.insetBy(dx: 132 * unit, dy: 132 * unit))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: CommandLine.arguments[1])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: set.appendingPathComponent(name))
    }
}
SWIFT
xcrun swiftc -O -swift-version 6 -o "$work/make-icon" "$work/main.swift" "$work/MenuBarIcon.swift"
"$work/make-icon" "$work/AppIcon.iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$work/AppIcon.iconset"

plist="$app/Contents/Info.plist"
cp Resources/Info.plist "$plist"
plutil -replace CFBundleShortVersionString -string "$bundle_version" "$plist"
plutil -replace CFBundleVersion -string "$bundle_version" "$plist"
plutil -replace CFBundleIconFile -string AppIcon "$plist"
plutil -lint "$plist" >/dev/null

if [ -n "$identity" ]; then
    codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$identity" "$app"
else
    codesign --force --options runtime --timestamp=none --sign - "$app"
fi
codesign --verify --strict --deep --verbose=2 "$app"
echo "bundled $app $version (bundle version $bundle_version)"
