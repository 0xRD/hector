#!/bin/sh
# Lists anything Hector left on this Mac. Needs neither root nor a password.
# Exit status: 0 when nothing is left, 1 otherwise.
set -u

found=0

report() {
    echo "left: $1"
    found=1
}

# Hector, then Netbite (its name before 0.4) in case an old install was never cleaned.
check() {
    label=$1 bundle=$2 name=$3
    for path in \
        "/Library/PrivilegedHelperTools/$label" \
        "/Library/LaunchDaemons/$label.plist" \
        "/Library/Application Support/$name" \
        "/Library/Logs/$name" \
        "/var/run/$label.sock" \
        "$HOME/Library/Application Support/$name" \
        "$HOME/Library/Caches/$bundle" \
        "$HOME/Library/HTTPStorages/$bundle" \
        "$HOME/Library/HTTPStorages/$bundle.binarycookies" \
        "$HOME/Library/Saved Application State/$bundle.savedState" \
        "$HOME/Library/Preferences/$bundle.plist"
    do
        [ -e "$path" ] || [ -L "$path" ] && report "$path"
    done

    launchctl print "system/$label" >/dev/null 2>&1 && report "launchd service system/$label"
    security authorizationdb read "$bundle.modify-firewall" >/dev/null 2>&1 && report "authorization right $bundle.modify-firewall"
    security find-generic-password -s "$bundle.virustotal" >/dev/null 2>&1 && report "Keychain item $bundle.virustotal"
    defaults read "$bundle" >/dev/null 2>&1 && report "preferences domain $bundle"
}

check io.github.0xrd.hectord io.github.0xrd.hector Hector
check io.github.0xrd.netbited io.github.0xrd.netbite Netbite
grep -q "netbite managed block" /etc/hosts && report "Netbite section in /etc/hosts"

if [ "$found" = 0 ]; then
    echo "Nothing left: Hector is fully removed."
    echo "(The pf anchor cannot be listed without root; check with: sudo pfctl -a com.apple/250.Netbite -s rules)"
fi
exit "$found"
