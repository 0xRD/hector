#!/bin/sh
# Lists anything Netbite left on this Mac. Needs neither root nor a password.
# Exit status: 0 when nothing is left, 1 otherwise.
set -u

LABEL=io.github.0xrd.netbited
BUNDLE=io.github.0xrd.netbite
found=0

report() {
    echo "left: $1"
    found=1
}

for path in \
    "/Library/PrivilegedHelperTools/$LABEL" \
    "/Library/LaunchDaemons/$LABEL.plist" \
    "/Library/Application Support/Netbite" \
    "/Library/Logs/Netbite" \
    "/var/run/$LABEL.sock" \
    "$HOME/Library/Application Support/Netbite" \
    "$HOME/Library/Caches/$BUNDLE" \
    "$HOME/Library/HTTPStorages/$BUNDLE" \
    "$HOME/Library/HTTPStorages/$BUNDLE.binarycookies" \
    "$HOME/Library/Saved Application State/$BUNDLE.savedState" \
    "$HOME/Library/Preferences/$BUNDLE.plist"
do
    [ -e "$path" ] || [ -L "$path" ] && report "$path"
done

launchctl print "system/$LABEL" >/dev/null 2>&1 && report "launchd service system/$LABEL"
grep -q "netbite managed block" /etc/hosts && report "Netbite section in /etc/hosts"
security authorizationdb read "$BUNDLE.modify-firewall" >/dev/null 2>&1 && report "authorization right $BUNDLE.modify-firewall"
security find-generic-password -s "$BUNDLE.virustotal" >/dev/null 2>&1 && report "Keychain item $BUNDLE.virustotal"
defaults read "$BUNDLE" >/dev/null 2>&1 && report "preferences domain $BUNDLE"

if [ "$found" = 0 ]; then
    echo "Nothing left: Netbite is fully removed."
    echo "(The pf anchor cannot be listed without root; check with: sudo pfctl -a com.apple/250.Netbite -s rules)"
fi
exit "$found"
