# Hector

**A calm guardian for your Mac: see what runs, what starts by itself, and who it talks to, then cut it off.**

Hector is an open-source security app for macOS, in the spirit of Objective-See's tools ([LuLu](https://objective-see.org/products/lulu.html), [KnockKnock](https://objective-see.org/products/knockknock.html), [TaskExplorer](https://objective-see.org/products/taskexplorer.html)) and [Little Snitch](https://www.obdev.at/products/littlesnitch/), built to run **without a paid Apple Developer account**. It gathers three views in one window:

- **Netbite**, the network module: which process talks to which server, where that server is, and blocking of domains, addresses and whole countries.
- **Persistence**: everything configured to start automatically (launch agents and daemons, login items, cron, extensions, profiles).
- **Processes**: what runs right now, who signed it, where it came from.

Code signatures are checked locally; VirusTotal lookups are optional, use your own free key, and send hashes only, never files.

The no-paid-account constraint shapes what the network module can do:

| | Hector (Netbite) | LuLu / Little Snitch |
|---|---|---|
| Which app connects to which IP, port, country | ✅ per process | ✅ |
| World map of destinations | ✅ | Little Snitch |
| Block a domain, IP, network or a whole country | ✅ **system-wide**, through `pf` and `/etc/hosts` | ✅ |
| Block a destination for **one app only** | ❌ needs a signed Network Extension | ✅ |
| Prompt on every new connection | ❌ same reason | ✅ |

Hector *observes per app* and *blocks for the whole Mac*. The [architecture notes](docs/ARCHITECTURE.md) explain why.

> **Status: early development (0.4).** Hector was called Netbite up to 0.3; updating replaces the old helper and keeps your blocklist, data and VirusTotal key. See the [roadmap](docs/ROADMAP.md).

## Install

Download the latest `Hector-x.y.z-macOS.zip` from [Releases](../../releases), move **Hector.app** to Applications, and open it. The release notes explain the one-time Gatekeeper step: Hector is not notarized, because notarization needs a paid Apple Developer account.

## Features available now

- **Netbite, live connections**: apps and their destinations, a world map with one line per destination (hover a line to see which app owns it), and a details panel with reverse DNS, country and the last minute of activity. Data comes from libproc, the same source `lsof -i` uses; helper processes are grouped under their app.
- **Blocking**: "Block this destination", "Block all of <country>", personal rules, and a Blocklists screen with pending changes. The `hectord` helper enforces them with pf and `/etc/hosts`, re-applies them at boot, and lets the app see system processes. Country blocking is opt-in, networks wider than /8 (IPv4) or /16 (IPv6) are refused, and local networks are never blocked.
- **Country of every destination**, offline, from the free [DB-IP Lite](https://db-ip.com/db/download/ip-to-country-lite) database.
- **Persistence**: launch agents and daemons, login items and background tasks (through the helper), cron and periodic jobs, system and kernel extensions, configuration profiles, browser extensions, each with its code signature and notes on anything odd.
- **Processes**: tree or flat list with user, arguments, signature, connections, and flags for code running from temporary, Downloads or hidden folders or deleted after launch; downloads show where they came from.
- **Security checkup**: SIP, Gatekeeper, XProtect, FileVault, firewall, automatic updates, Remote Login, Screen Sharing and Remote Management, File Sharing, Remote Apple Events, automatic login, guest account and MDM enrollment, each with what was found and how to fix it, and a button to the right System Settings pane. Read-only, without root or a password.
- **VirusTotal**: hash lookups for one item or all, within the free tier (4 per minute, 500 per day), cached for 7 days. The key stays in your Keychain (Settings, ⌘,).
- **Command line**: everything above is also in `hector` (`connections`, `geo`, `rules`, `helper`, `persistence`, `processes`, `checkup`, `sign`, `vt`).

## Requirements

- macOS 15 or later (Apple silicon or Intel)
- Swift 6: Xcode 16 or later, or the matching Command Line Tools

## Build and test

```bash
swift build -c release
```

```bash
scripts/test.sh
```

`scripts/test.sh` runs `swift test`, adding the Swift Testing plugin path that SwiftPM forgets when only the Command Line Tools are installed.

The binary is `.build/release/hector`.

To build the app as `Hector.app`, ad-hoc signed (no developer account needed), then open it:

```bash
scripts/bundle-app.sh
```

```bash
open .build/Hector.app
```

During development, `swift run HectorApp` starts the app without bundling it.

If `swift build` crashes with `Symbol not found … BuildServerProtocol`, or complains that the SDK is not supported by the compiler, your Command Line Tools do not match their own SDK (Command Line Tools 26.6 ships that way). Install Command Line Tools for Xcode 27 or later, or Xcode. Until then, `scripts/build.sh` builds the CLI with `swiftc` directly, picking an SDK the compiler can load. Tests still need SwiftPM.

```bash
scripts/build.sh
```

That one writes `.build/manual/hector`.

## Usage

```bash
hector connections
```

```text
Example Browser  com.example.browser  (pid 4321)
  ├ udp 198.51.100.20:443                           US
  ├ tcp 203.0.113.7:443                             DE   ESTABLISHED
  └ tcp [2001:db8::25]:5228                         --   ESTABLISHED
```

As a normal user you see your own processes. Run it with `sudo` to include system daemons. Add `--resolve` for reverse DNS, `--json` for machine-readable output, and `--all` to include listening sockets.

```bash
hector checkup
```

Reviews the security settings of this Mac and prints how to fix each one that needs it. It only reads; `--json` for scripts.

```bash
hector geo update
```

Downloads the country database to `~/Library/Application Support/Hector/`.

```bash
hector geo lookup 140.82.121.4
```

```bash
hector geo ranges CN --count
```

```bash
hector rules example > blocklist.json
```

Edit the file: add rules, and list the countries to block in `"blockedCountries"` (for example `["CN", "RU"]`).

```bash
hector rules check blocklist.json
```

```bash
hector rules render blocklist.json --out ./out
```

`rules render` writes the pf ruleset, the two tables and the resulting hosts file into `./out` and prints the commands the helper will run. **It changes nothing on your system.**

Once the helper is installed (from the app, or with `sudo hectord install`), the CLI can drive it too:

```bash
hector helper apply blocklist.json
```

```bash
hector helper status
```

```bash
hector helper flush
```

`flush` removes every Hector rule and the managed `/etc/hosts` section; the helper stays installed.

## Uninstall

Choose **Hector → Uninstall Hector…** in the menu bar. It removes, after one administrator password:

- every blocking rule (the pf anchor, its pf reference, the Netbite section of `/etc/hosts`);
- the helper, its LaunchDaemon, its data in `/Library/Application Support/Hector`, its logs in `/Library/Logs/Hector` and its authorization right;
- your blocklist, the country database, preferences, caches and saved window state in your Library;
- the VirusTotal API key in your Keychain, if you saved one;
- the app itself, moved to the Trash.

Without the app: `sudo /Library/PrivilegedHelperTools/io.github.0xrd.hectord uninstall --purge`, then delete `~/Library/Application Support/Hector`.

To check that nothing is left, without root: `scripts/check-uninstall.sh`.

## Privacy

Hector has no telemetry, no account and no server. Everything stays on your Mac. It makes only two kinds of network requests: the DB-IP database download, when you start it from the CLI (`hector geo update`) or the app, and reverse DNS lookups of the addresses your apps already contact, through your system resolver. The starting point of the map is the region set in macOS, not a location lookup.

## Project layout

```
Sources/HectorCore/   Library shared by the CLI, the app and the helper
  Net/                 IPAddress, CIDR
  Collector/           Socket enumeration per process (libproc)
  GeoIP/               DB-IP loader, country lookups, range → CIDR conversion, updater
  Rules/               Blocklist model, compiler, pf anchor and /etc/hosts rendering
Sources/hector/       Command-line tool
Sources/HectorApp/    SwiftUI app: live monitor, world map, details panel, blocklists
Sources/hectord/      Privileged helper (root): enforces blocklists with pf and /etc/hosts
Tests/HectorCoreTests Swift Testing suites
docs/                  Architecture and roadmap
scripts/test.sh        swift test, working around Command Line Tools without Xcode
scripts/check-uninstall.sh
                       Lists anything Hector left on this Mac
scripts/build.sh       swiftc-only build of the CLI, for broken toolchains
scripts/bundle-app.sh  Builds and ad-hoc signs .build/Hector.app (--universal, --zip)
.github/workflows/     CI on every push, release on every v* tag
scripts/generate-world-data.py
                       Regenerates the map data from Natural Earth
```

## Security

The helper runs as root. [SECURITY.md](SECURITY.md) describes the threat model, the review done before 0.3, the remaining risks, and how to report a vulnerability privately.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

Hector is free software, released under the [GNU General Public License v3.0](LICENSE).

IP geolocation by [DB-IP](https://db-ip.com), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The database is downloaded at runtime and is not redistributed in this repository.

Map data derived from [Natural Earth](https://www.naturalearthdata.com) (public domain).
