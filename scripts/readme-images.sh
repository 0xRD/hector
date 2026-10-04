#!/bin/sh
# Renders the images of the README into docs/images: the app icon, the wordmark (light and dark),
# and screenshots of the main screens in both appearances.
#
# The screenshots use the debug build's demo mode (HECTOR_DEMO=1, see Sources/HectorApp/DemoData.swift):
# documentation IP ranges, example.com hosts and made-up apps, nothing read from this Mac. The app
# runs in English with a US locale, so dates and numbers do not depend on this Mac's settings.
#
# Usage:  scripts/readme-images.sh
set -eu

cd "$(dirname "$0")/.."
OUT=docs/images
WIDTH=1440
swift build --product HectorApp
APP="$(swift build --show-bin-path)/HectorApp"
mkdir -p "$OUT"

# Takes the environment variables as arguments: in sh, assignments in front of a function call
# would outlive the call.
run() {
    env "$@" "$APP" -AppleLanguages '(en)' -AppleLocale en_US >/dev/null
}

run HECTOR_RENDER_BRAND="$OUT"

for appearance in light dark; do
    for screen in connections blocklists persistence processes checkup; do
        file="$OUT/$screen-$appearance.png"
        if [ "$screen" = connections ]; then
            # Safari's first line to Europe, selected so the details panel shows.
            run HECTOR_DEMO=1 HECTOR_APPEARANCE="$appearance" HECTOR_DEBUG_SELECT=12 HECTOR_SNAPSHOT="$file"
        else
            run HECTOR_DEMO=1 HECTOR_APPEARANCE="$appearance" HECTOR_DEBUG_SCREEN="$screen" HECTOR_SNAPSHOT="$file" \
                HECTOR_SNAPSHOT_DELAY=4
        fi
        sips --resampleWidth "$WIDTH" "$file" >/dev/null
    done
done
echo "Wrote $OUT"
