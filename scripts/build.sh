#!/bin/sh
# Builds the hector CLI with swiftc directly, for machines where `swift build` is unavailable or
# broken (for example a Command Line Tools install whose SwiftPM and SDK versions do not match).
# Prefer `swift build` and `swift test` whenever they work; tests need SwiftPM.
#
# Usage:  scripts/build.sh
# Output: .build/manual/hector
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

$SWIFTC -O -module-name HectorCore -parse-as-library -emit-library -static \
    -emit-module -emit-module-path "$OUT/HectorCore.swiftmodule" \
    -o "$OUT/libHectorCore.a" $(find Sources/HectorCore -name '*.swift')
$SWIFTC -O -module-name hector -I "$OUT" -L "$OUT" -lHectorCore \
    -o "$OUT/hector" $(find Sources/hector -name '*.swift')
echo "Built $OUT/hector (SDK: $SDKROOT)"
