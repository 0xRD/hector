#!/bin/sh
# Builds Netbite.app: a release build of the NetbiteApp target wrapped in an app bundle,
# ad-hoc signed (no Apple Developer account needed).
#
# Usage:  scripts/bundle-app.sh
# Output: .build/Netbite.app
set -eu

cd "$(dirname "$0")/.."
VERSION=0.2.0
APP=.build/Netbite.app

swift build -c release --product NetbiteApp
BIN="$(swift build -c release --show-bin-path)/NetbiteApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Netbite"
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

codesign --force --sign - "$APP"
echo "Built $APP"
