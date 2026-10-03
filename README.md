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

> **Status: early development.** The core library and the `netbite` command-line tool work today. The SwiftUI app and the privileged helper that applies rules are next; see the [roadmap](docs/ROADMAP.md).

## Features available now

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
swift test
```

The binary is `.build/release/netbite`.

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
  ├ udp 198.51.100.20:443                          US
  ├ tcp 203.0.113.7:443                           US   ESTABLISHED
  └ tcp 192.0.2.188:5228                         US   ESTABLISHED
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

## Privacy

Netbite has no telemetry, no account and no server. Everything stays on your Mac. The only network request it makes is the monthly download of the DB-IP database, and only when you run `netbite geo update`.

## Project layout

```
Sources/NetbiteCore/   Library shared by the CLI, the app and the helper
  Net/                 IPAddress, CIDR
  Collector/           Socket enumeration per process (libproc)
  GeoIP/               DB-IP loader, country lookups, range → CIDR conversion, updater
  Rules/               Blocklist model, compiler, pf anchor and /etc/hosts rendering
Sources/netbite/       Command-line tool
Tests/NetbiteCoreTests Swift Testing suites
docs/                  Architecture and roadmap
scripts/build.sh       swiftc-only build, for broken toolchains
```

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

Netbite is free software, released under the [GNU General Public License v3.0](LICENSE).

IP geolocation by [DB-IP](https://db-ip.com), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The database is downloaded at runtime and is not redistributed in this repository.
