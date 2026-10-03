# Architecture

## Constraint: no paid Apple Developer account

Per-app firewalls on macOS (LuLu, Little Snitch) are built on a **Network Extension** content filter (`NEFilterDataProvider`) running as a System Extension. Loading one requires:

- the `com.apple.developer.networking.networkextension` entitlement, which only paid developer accounts can obtain;
- Developer ID signing and notarization, so that users can install it without disabling System Integrity Protection.

Netbite is meant to be built and used by anyone from source, so it does not depend on either. It uses only interfaces that work for an unsigned or ad-hoc signed binary:

| Need | Interface | Privilege |
|---|---|---|
| Sockets of each process | `libproc` (`proc_pidinfo`, `proc_pidfdinfo`) | user for own processes, root for all |
| Country of an IP | DB-IP Lite CSV, in memory | none |
| Block IPs, networks, countries | `pf` tables in an anchor | root |
| Block domains | managed section of `/etc/hosts` | root |

The consequence is the main trade-off of the project: **visibility is per app, blocking is system-wide.** `pf` and `/etc/hosts` have no notion of which process opened a socket.

A Network Extension can be added later as an optional component for people who hold a developer account. The core library is designed so that the same blocklist could feed it.

## Components

```
┌──────────────────────────┐      ┌────────────────────────────┐
│ Netbite.app (SwiftUI)    │      │ netbite (CLI)              │
│ connections · map · rules│      │ connections · geo · rules  │
└────────────┬─────────────┘      └─────────────┬──────────────┘
             │ links                            │ links
             ▼                                  ▼
┌────────────────────────────────────────────────────────────────┐
│ NetbiteCore                                                    │
│  Collector ── SocketCollector: pids → fds → socket_fdinfo      │
│  GeoIP ────── GeoIPDatabase (sorted ranges, binary search)     │
│               GeoIPUpdater (monthly DB-IP download)            │
│  Rules ────── Blocklist (JSON) → RuleCompiler → CompiledBlock- │
│               list → PFAnchor (ruleset, tables) + HostsFile    │
└────────────────────────────────────────────────────────────────┘
             │ compiled blocklist (planned: XPC)
             ▼
┌──────────────────────────┐
│ netbited (root, planned) │──► pfctl -a com.apple/250.Netbite …
│ applies, verifies, rolls │──► /etc/hosts managed section
│ back                     │
└──────────────────────────┘
```

- **NetbiteCore** has no UI and no privileged code. Everything in it is unit tested.
- **netbite** is the command-line front end. It is also the reference client while the app is being built.
- **Netbite.app** (planned) is a SwiftUI app with the connections list, the world map, the details panel and the blocklist editor. The design mockup covers both screens.
- **netbited** (planned) is the only component that runs as root. It is deliberately small: it receives a blocklist, compiles it with NetbiteCore, writes the files and runs `pfctl`.

## Collector

`SocketCollector.snapshot()` takes a couple of milliseconds (1.5 ms measured as a normal user on an M-series Mac), cheap enough to poll every second:

1. `proc_listallpids` lists the processes.
2. For each pid, `proc_pidinfo(PROC_PIDLISTFDS)` lists its file descriptors. It fails with `EPERM` for processes of other users unless we run as root; those are counted, not hidden.
3. For each socket descriptor, `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` returns `socket_fdinfo`. Netbite keeps TCP and UDP sockets of the IPv4 and IPv6 families.
4. Addresses are normalized: IPv4-mapped IPv6 becomes IPv4, and the interface index the kernel embeds in link-local addresses is cleared.
5. The executable path is mapped to its **outermost** `.app` bundle, so helper processes group under the app the user recognizes.

### Known limits

- **Host names.** A socket only knows the IP address. Reverse DNS (`--resolve`) returns PTR records, such as `fra16s50-in-f4.1e100.net`, not the name the app asked for. Attributing real names needs a view of DNS answers: see the roadmap.
- **Traffic volume.** Byte counters per connection are not exposed by libproc. `nettop` gets them from the private NetworkStatistics framework; that is planned as an optional source.
- **GeoIP load time.** Parsing the 700,000-line CSV takes about 1 s. The app loads it once at launch; a compact binary cache is planned so the CLI starts instantly too.
- **Short-lived connections** that open and close between two snapshots are missed. Polling every second catches most of them.

## Blocking

### pf anchor

The stock `/etc/pf.conf` of macOS contains `anchor "com.apple/*"`. Netbite loads its rules into the sub-anchor `com.apple/250.Netbite`, so:

- `/etc/pf.conf` is never modified, and macOS updates cannot overwrite our rules;
- `pfctl -a com.apple/250.Netbite -F all` removes every Netbite rule at once.

The ruleset is generated by `PFAnchor.ruleset(tableDirectory:)`:

```
table <netbite_block> persist file ".../netbite_block.table"
table <netbite_geo>   persist file ".../netbite_geo.table"
block return out quick to <netbite_block>
block return out quick to <netbite_geo>
block drop in quick from <netbite_geo>
```

- `block return` answers with a TCP reset or an ICMP unreachable, so blocked apps fail at once instead of hanging until a timeout.
- `<netbite_block>` holds the user's IPs and networks.
- `<netbite_geo>` holds every range of every blocked country. Blocking China and Russia is about 38,000 networks; pf tables are radix trees and handle that without measurable cost.
- pf is enabled with `pfctl -E`, which is reference-counted, so Netbite does not turn pf off for other software that also uses it.

### /etc/hosts

Domains go to a section delimited by markers. `HostsFile.render` replaces only that section and leaves every other line byte-for-byte identical. Each domain points to `0.0.0.0` and `::`. After writing, the DNS cache is flushed.

Limits of this approach, documented in the UI as well:

- `*.example.com` cannot be expressed in a hosts file; only the apex is blocked and a warning is shown.
- Apps that use their own DNS-over-HTTPS resolver (some browsers) bypass `/etc/hosts`. Blocking the IP or the country still works for them.

### Safety rails

`RuleCompiler` refuses:

- networks wider than /8 (IPv4) or /16 (IPv6): a typo such as `/2` would cut the Mac off the internet;
- loopback, private, link-local, CGNAT and multicast ranges.

Country blocking is **opt-in**: `Blocklist.blockedCountries` is empty by default.

## Privileged helper (planned)

Running pfctl and writing `/etc/hosts` needs root. Without a developer account, `SMAppService` daemons and `SMJobBless` are not usable in a distributable way. The plan:

1. On first use, the app asks for an administrator password once, then installs `netbited` and its LaunchDaemon plist under `/Library`.
2. The app talks to `netbited` over a Unix domain socket owned by root, mode 0660, group `admin`. The protocol is a small JSON message: "apply this blocklist" or "remove everything".
3. `netbited` revalidates everything it receives. It never trusts compiled output from the client and compiles the blocklist itself with NetbiteCore.
4. Every apply keeps the previous state, so it can roll back if `pfctl` fails.
5. Uninstalling runs the flush command and removes the managed `/etc/hosts` section.

## Distribution

Without notarization, Gatekeeper blocks downloaded binaries. Two ways to install:

- build from source (recommended, a single `swift build`);
- use ad-hoc signed release builds, which users open with a right click → Open the first time.
