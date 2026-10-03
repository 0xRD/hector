#!/bin/sh
# Builds Netbite with swiftc directly, for machines where `swift build` is unavailable or broken
# (for example a Command Line Tools install whose SwiftPM and SDK versions do not match).
# Prefer `swift build` / `swift test` when they work.
#
# Usage: scripts/build.sh [build|test]     (default: build)
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

core_sources=$(find Sources/NetbiteCore -name '*.swift')

case "${1:-build}" in
build)
    $SWIFTC -O -module-name NetbiteCore -parse-as-library -emit-library -static \
        -emit-module -emit-module-path "$OUT/NetbiteCore.swiftmodule" \
        -o "$OUT/libNetbiteCore.a" $core_sources
    $SWIFTC -O -module-name netbite -I "$OUT" -L "$OUT" -lNetbiteCore \
        -o "$OUT/netbite" $(find Sources/netbite -name '*.swift')
    echo "Built $OUT/netbite (SDK: $SDKROOT)"
    ;;
test)
    TESTOUT="$OUT/test"
    FRAMEWORKS="$(dirname "$(dirname "$(xcrun --find swiftc)")")/../Library/Developer/Frameworks"
    [ -d "$FRAMEWORKS" ] || FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    PLUGINS="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift/host/plugins/testing"
    mkdir -p "$TESTOUT"
    $SWIFTC -Onone -enable-testing -module-name NetbiteCore -parse-as-library -emit-library -static \
        -emit-module -emit-module-path "$TESTOUT/NetbiteCore.swiftmodule" \
        -o "$TESTOUT/libNetbiteCore.a" $core_sources
    printf 'import Testing\n@main struct Runner { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n' > "$TESTOUT/Runner.swift"
    $SWIFTC -Onone -module-name NetbiteCoreTests -parse-as-library -I "$TESTOUT" -L "$TESTOUT" -lNetbiteCore \
        -F "$FRAMEWORKS" -framework Testing -plugin-path "$PLUGINS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -o "$TESTOUT/run-tests" $(find Tests/NetbiteCoreTests -name '*.swift') "$TESTOUT/Runner.swift"
    "$TESTOUT/run-tests"
    ;;
*)
    echo "usage: $0 [build|test]" >&2
    exit 64
    ;;
esac
