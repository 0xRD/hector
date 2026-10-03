#!/bin/sh
# Builds the netbite CLI with swiftc directly, for machines where `swift build` is unavailable or
# broken (for example a Command Line Tools install whose SwiftPM and SDK versions do not match).
# Prefer `swift build` and `swift test` whenever they work; tests need SwiftPM.
#
# Usage:  scripts/build.sh
# Output: .build/manual/netbite
set -eu

cd "$(dirname "$0")/.."
OUT=.build/manual
TARGET="$(uname -m)-apple-macos15"

# Pick the newest SDK this compiler can actually load.
if [ -z "${SDKROOT:-}" ]; then
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.*.sdk "$(xcrun --show-sdk-path 2>/dev/null)" 2>/dev/null | sort -rV); do
        if echo 'let x = 1' | swiftc -sdk "$sdk" -target "$TARGET" -typecheck - >/dev/null 2>&1; then
            SDKROOT="$sdk"
            break
        fi
    done
fi
: "${SDKROOT:?No usable macOS SDK found}"
SWIFTC="swiftc -sdk $SDKROOT -target $TARGET -swift-version 6"
mkdir -p "$OUT"

$SWIFTC -O -module-name NetbiteCore -parse-as-library -emit-library -static \
    -emit-module -emit-module-path "$OUT/NetbiteCore.swiftmodule" \
    -o "$OUT/libNetbiteCore.a" $(find Sources/NetbiteCore -name '*.swift')
$SWIFTC -O -module-name netbite -I "$OUT" -L "$OUT" -lNetbiteCore \
    -o "$OUT/netbite" $(find Sources/netbite -name '*.swift')
echo "Built $OUT/netbite (SDK: $SDKROOT)"
