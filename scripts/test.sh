#!/bin/sh
# Runs the test suite. With the Command Line Tools alone (no Xcode), SwiftPM does not pass the
# path of the Swift Testing macro plugin to the compiler, so pass it here. Extra arguments go to
# `swift test`.
set -eu
cd "$(dirname "$0")/.."

PLUGINS="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing"
if xcode-select -p | grep -q CommandLineTools && [ -d "$PLUGINS" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
