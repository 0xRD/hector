## What's new in 0.4

Netbite becomes **Hector**, a small all-in-one security app for macOS. Netbite stays the name of its network module, and 0.3 installs move over on their own: helper, blocklist, country database and VirusTotal key.

- **Connections:** an interactive map, with one line and a count bubble per country, a country filter, and zoom and pan. Network names (AS numbers and organizations) come from a second free DB-IP database.
- **Blocklists:** StevenBlack Unified and EasyPrivacy hosts lists, downloaded and checked by the helper every week.
- **Persistence:** launch agents and daemons, login items, background tasks, extensions, cron, profiles and browser extensions, each with its code signature.
- **Processes:** the process tree with signatures, arguments, connections and flags for code running from odd places.
- **Checkup:** SIP, Gatekeeper, XProtect, FileVault, firewall, updates, sharing services and more, each with how to fix it.
- **Keyboard taps:** apps that receive your keystrokes.
- **Camera & mic:** a log of when they turn on and off, naming the app (from the microphone's clients, and the camera's green indicator).
- **VirusTotal:** look up files by hash with your own free key (Settings → VirusTotal). Files are never uploaded.
- The `hector` command-line tool does all of this from a terminal.
- **Lighter and harder to abuse** (0.4.1 and 0.4.2): nothing is refreshed while the window is hidden, the IP databases take about 4 MB each instead of 110 MB, the camera and microphone monitor sleeps while no microphone runs, and the root helper downloads as `nobody` and runs in a sandbox that only lets it write its own files and start its own tools. Update the helper from Blocklists after installing.
- **0.4.3:** Hector can live in the menu bar: closing the window keeps it running (camera and microphone log included), and Settings → General has "Open Hector at login" and "Keep running in the menu bar". Fixes: the blocking status now counts hosts lists; dates and numbers use English words whatever the system language; tools installed in versioned folders get their real name; Persistence dims empty leftover jobs, judges `open` jobs by the app they open, and recognizes Hector's own helper.
- **0.4.4:** an allowlist in Blocklists (it wins over the lists and your own domain rules, and says so on each rule it cancels), the HaGeZi Light list, and a tidier interface: search and the details panel only where they apply, the panel opens when you pick something, Processes hides Apple's own processes by default, Keyboard taps groups identical taps and hides switched-off ones, Camera & mic shows what is on first, Connections shows one row per address with its ports, keyboard shortcuts for the map, and optional automatic VirusTotal lookups. Update the helper from Blocklists after installing: the allowlist needs it.
- **0.4.5:** fixes 0.4.4 hanging at launch (100% CPU, no window) when macOS hides the menu bar icon because the menu bar is full. Releases are now launched on CI before they are published.
- **0.4.6:** fixes hosts lists failing to download with the 0.4.5 helper ("error 1"): download children now make their own temporary folder after giving up root, and errors say what went wrong. Update the helper from Blocklists, then Update Now.
- **0.4.7:** Processes has a right-click menu on every row (Reveal in Finder, Copy path, Copy PID, Open Activity Monitor) and can quit your own processes after asking; apps are asked to quit normally, so they can offer to save. Other users' and the system's processes cannot be quit from Hector.

## Install

With Homebrew: `brew install --cask 0xrd/tap/hector` (or `brew upgrade` if you installed it that way), then step 3 below; after an upgrade, open **Blocklists** and click **Update helper…**. Otherwise:

1. Download **Hector-{{VERSION}}-macOS.zip** below and open it.
2. Move **Hector.app** to your Applications folder.
3. Open it. Hector is not notarized by Apple (that needs a paid developer account), so macOS refuses the first launch:
   - open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Hector message;
   - or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Hector.app`
4. To block destinations, open **Blocklists** and click **Install helper…**. macOS asks for an administrator password once.

Hector runs on macOS 15 or later, on Apple silicon and Intel.

The command-line tool ships inside the app. To use it from a terminal:

```
sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/Hector.app/Contents/Helpers/hector /usr/local/bin/hector
```

## Uninstall

Choose **Hector → Uninstall Hector…** in the menu bar, or **Settings → General → Uninstall Hector…**. It removes every rule, the helper and its logs, your blocklist, the country database, preferences, caches and the VirusTotal key, then moves the app to the Trash. macOS asks for an administrator password once.

## Verify the download

SHA-256 of the zip: `{{SHA256}}`

```
shasum -a 256 Hector-{{VERSION}}-macOS.zip
```

The app is built by GitHub Actions from the tagged source, with the workflow in `.github/workflows/release.yml`.
