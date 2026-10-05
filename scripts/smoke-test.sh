#!/bin/sh
# Launches a built Hector.app for a while and fails if it crashes, keeps a CPU busy or keeps
# growing: what unit tests cannot see (SwiftUI update loops, a crash at launch). 0.4.4 shipped
# with such a loop: built with the macOS 15 SDK, it spun at 100% CPU on macOS 26.
#
# Usage:  scripts/smoke-test.sh [path/to/Hector.app] [seconds]
set -eu

APP="${1:-.build/Hector.app}"
SECONDS_TO_RUN="${2:-20}"
BINARY="$APP/Contents/MacOS/Hector"
[ -x "$BINARY" ] || { echo "smoke test: $BINARY not found" >&2; exit 1; }

"$BINARY" >/tmp/hector-smoke.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

# Let it start, then sample once per second.
sleep 5
busy=0
samples=0
first_rss=""
last_rss=0
elapsed=0
while [ "$elapsed" -lt "$SECONDS_TO_RUN" ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "smoke test: Hector exited after $((elapsed + 5)) s" >&2
        tail -20 /tmp/hector-smoke.log >&2
        exit 1
    fi
    set -- $(ps -o %cpu= -o rss= -p "$PID")
    cpu=${1%%.*}
    last_rss=$2
    [ -n "$first_rss" ] || first_rss=$last_rss
    [ "$cpu" -ge 80 ] && busy=$((busy + 1))
    samples=$((samples + 1))
    sleep 1
    elapsed=$((elapsed + 1))
done

growth=$(( (last_rss - first_rss) / 1024 ))
echo "smoke test: $samples samples, $busy at 80% CPU or more, memory grew by $growth MB"
# A hang pins a core in every sample; a little startup work does not.
if [ "$busy" -gt $((samples / 2)) ]; then
    echo "smoke test: Hector keeps a CPU busy (update loop?)" >&2
    exit 1
fi
if [ "$growth" -gt 200 ]; then
    echo "smoke test: memory keeps growing" >&2
    exit 1
fi
echo "smoke test: passed"
