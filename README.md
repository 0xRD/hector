# Netbite

**See which process on your Mac talks to which server, where that server is, and cut it off.**

Netbite is an open-source network monitor for macOS, in the spirit of [LuLu](https://objective-see.org/products/lulu.html) and [Little Snitch](https://www.obdev.at/products/littlesnitch/), built to run **without a paid Apple Developer account**. That constraint shapes what it can do:

| | Netbite | LuLu / Little Snitch |
|---|---|---|
| Which app connects to which IP, port, country | ✅ per process | ✅ |
| World map of destinations | ✅ (app, planned) | Little Snitch |
| Block a domain, IP, network or a whole country | ✅ **system-wide**, through `pf` and `/etc/hosts` | ✅ |
| Block a destination for **one app only** | ❌ needs a signed Network Extension | ✅ |
| Prompt on every new connection | ❌ same reason | ✅ |

Netbite *observes per app* and *blocks for the whole Mac*. The [architecture notes](docs/ARCHITECTURE.md) explain why.

> **Status: early development (0.3).** The app watches connections and blocks destinations and countries through its privileged helper. Netbite is growing into **Hexorcist**, an all-in-one security app (persistence, processes, VirusTotal); see the [roadmap](docs/ROADMAP.md).

## Install

Download the latest `Netbite-x.y.z-macOS.zip` from [Releases](../../releases), move **Netbite.app** to Applications, and open it. The release notes explain the one-time Gatekeeper step: Netbite is not notarized, because notarization needs a paid Apple Developer account.

## Features available now

- **Netbite.app**: live list of apps and their destinations, a world map with one line per destination (hover a line to see which app owns it), and a details panel with reverse DNS, country and the last minute of activity.
- **Blocking**: "Block this destination", "Block all of <country>", personal rules, and a Blocklists screen with pending changes. The `netbited` helper enforces them with pf and `/etc/hosts`, re-applies them at boot, and lets the app see system processes.
- **Live connections per process** through libproc, the same source `lsof -i` uses. Helper processes are grouped under their app, so Chrome's renderers show up as "Google Chrome".
- **Country of every destination**, offline, from the free [DB-IP Lite](https://db-ip.com/db/download/ip-to-country-lite) database (about 700,000 ranges, 250 countries).
- **Blocklist compiler**: domains, IPs, CIDR ranges and countries are turned into a pf ruleset, two pf tables and a managed `/etc/hosts` section.
- **Country blocking is opt-in.** No country is blocked by default; you switch on the ones you want.
- **Safety rails**: networks wider than /8 (IPv4) or /16 (IPv6) are refused, and local or private networks are never blocked.

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

The binary is `.build/release/netbite`.

To build the app as `Netbite.app`, ad-hoc signed (no developer account needed), then open it:

```bash
scripts/bundle-app.sh
```

```bash
open .build/Netbite.app
```

During development, `swift run NetbiteApp` starts the app without bundling it.

If `swift build` crashes with `Symbol not found … BuildServerProtocol`, or complains that the SDK is not supported by the compiler, your Command Line Tools do not match their own SDK (Command Line Tools 26.6 ships that way). Install Command Line Tools for Xcode 27 or later, or Xcode. Until then, `scripts/build.sh` builds the CLI with `swiftc` directly, picking an SDK the compiler can load. Tests still need SwiftPM.

```bash
scripts/build.sh
```

That one writes `.build/manual/netbite`.

## Usage

```bash
netbite connections
```

```text
Example Browser  com.example.browser  (pid 4321)
  ├ udp 198.51.100.20:443                           US
  ├ tcp 203.0.113.7:443                             DE   ESTABLISHED
  └ tcp [2001:db8::25]:5228                         --   ESTABLISHED
```

As a normal user you see your own processes. Run it with `sudo` to include system daemons. Add `--resolve` for reverse DNS, `--json` for machine-readable output, and `--all` to include listening sockets.

```bash
netbite geo update
```

Downloads the country database to `~/Library/Application Support/Netbite/`.

```bash
netbite geo lookup 140.82.121.4
```

```bash
netbite geo ranges CN --count
```

```bash
netbite rules example > blocklist.json
```

Edit the file: add rules, and list the countries to block in `"blockedCountries"` (for example `["CN", "RU"]`).

```bash
netbite rules check blocklist.json
```

```bash
netbite rules render blocklist.json --out ./out
```

`rules render` writes the pf ruleset, the two tables and the resulting hosts file into `./out` and prints the commands the helper will run. **It changes nothing on your system.**

Once the helper is installed (from the app, or with `sudo netbited install`), the CLI can drive it too:

```bash
netbite helper apply blocklist.json
```

```bash
netbite helper status
```

```bash
netbite helper flush
```

`flush` removes every Netbite rule and the managed `/etc/hosts` section; the helper stays installed.

## Uninstall

Choose **Netbite → Uninstall Netbite…** in the menu bar. It removes, after one administrator password:

- every blocking rule (the pf anchor, its pf reference, the Netbite section of `/etc/hosts`);
- the helper, its LaunchDaemon, its data in `/Library/Application Support/Netbite`, its logs in `/Library/Logs/Netbite` and its authorization right;
- your blocklist, the country database, preferences, caches and saved window state in your Library;
- the VirusTotal API key in your Keychain, if you saved one;
- the app itself, moved to the Trash.

Without the app: `sudo /Library/PrivilegedHelperTools/io.github.0xrd.netbited uninstall --purge`, then delete `~/Library/Application Support/Netbite`.

To check that nothing is left, without root: `scripts/check-uninstall.sh`.

## Privacy

Netbite has no telemetry, no account and no server. Everything stays on your Mac. It makes only two kinds of network requests: the DB-IP database download, when you start it from the CLI (`netbite geo update`) or the app, and reverse DNS lookups of the addresses your apps already contact, through your system resolver. The starting point of the map is the region set in macOS, not a location lookup.

## Project layout

```
Sources/NetbiteCore/   Library shared by the CLI, the app and the helper
  Net/                 IPAddress, CIDR
  Collector/           Socket enumeration per process (libproc)
  GeoIP/               DB-IP loader, country lookups, range → CIDR conversion, updater
  Rules/               Blocklist model, compiler, pf anchor and /etc/hosts rendering
Sources/netbite/       Command-line tool
Sources/NetbiteApp/    SwiftUI app: live monitor, world map, details panel, blocklists
Sources/netbited/      Privileged helper (root): enforces blocklists with pf and /etc/hosts
Tests/NetbiteCoreTests Swift Testing suites
docs/                  Architecture and roadmap
scripts/test.sh        swift test, working around Command Line Tools without Xcode
scripts/check-uninstall.sh
                       Lists anything Netbite left on this Mac
scripts/build.sh       swiftc-only build of the CLI, for broken toolchains
scripts/bundle-app.sh  Builds and ad-hoc signs .build/Netbite.app (--universal, --zip)
.github/workflows/     CI on every push, release on every v* tag
scripts/generate-world-data.py
                       Regenerates the map data from Natural Earth
```

## Security

The helper runs as root. [SECURITY.md](SECURITY.md) describes the threat model, the review done before 0.3, the remaining risks, and how to report a vulnerability privately.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

Netbite is free software, released under the [GNU General Public License v3.0](LICENSE).

IP geolocation by [DB-IP](https://db-ip.com), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The database is downloaded at runtime and is not redistributed in this repository.

Map data derived from [Natural Earth](https://www.naturalearthdata.com) (public domain).
