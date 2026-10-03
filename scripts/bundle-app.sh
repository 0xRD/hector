#!/bin/sh
# Builds Netbite.app: release builds of the app, the CLI and the privileged helper wrapped in an
# app bundle, ad-hoc signed (no Apple Developer account needed).
#
# Usage:  scripts/bundle-app.sh [--universal] [--zip]
#   --universal  build for Apple silicon and Intel (needs Xcode's build system)
#   --zip        also write .build/Netbite-<version>-macOS.zip, ready to upload
# Output: .build/Netbite.app
set -eu

cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/NetbiteCore/Helper/HelperProtocol.swift)
APP=.build/Netbite.app
ARCH_FLAGS=""
ZIP=0
for arg in "$@"; do
    case "$arg" in
    --universal) ARCH_FLAGS="--arch arm64 --arch x86_64" ;;
    --zip) ZIP=1 ;;
    *) echo "usage: $0 [--universal] [--zip]" >&2; exit 64 ;;
    esac
done

# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/NetbiteApp" "$APP/Contents/MacOS/Netbite"
# The CLI and the helper live in Helpers/: "netbite" next to "Netbite" would collide on a
# case-insensitive disk.
cp "$BIN/netbite" "$BIN/netbited" "$APP/Contents/Helpers/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Netbite</string>
    <key>CFBundleDisplayName</key><string>Netbite</string>
    <key>CFBundleIdentifier</key><string>io.github.0xrd.netbite</string>
    <key>CFBundleExecutable</key><string>Netbite</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Netbite contributors. GPL-3.0.</string>
</dict>
</plist>
PLIST

# Inner code first, then the bundle that seals it.
codesign --force --sign - "$APP/Contents/Helpers/netbite" "$APP/Contents/Helpers/netbited"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION)"

if [ "$ZIP" = 1 ]; then
    ARCHIVE=".build/Netbite-$VERSION-macOS.zip"
    rm -f "$ARCHIVE"
    # ditto keeps the signature and extended attributes intact, unlike zip.
    ditto -c -k --keepParent "$APP" "$ARCHIVE"
    shasum -a 256 "$ARCHIVE" | tee "$ARCHIVE.sha256"
fi
