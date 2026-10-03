# Architecture

## Constraint: no paid Apple Developer account

Per-app firewalls on macOS (LuLu, Little Snitch) are built on a **Network Extension** content filter (`NEFilterDataProvider`) running as a System Extension. Loading one requires:

- the `com.apple.developer.networking.networkextension` entitlement, which only paid developer accounts can obtain;
- Developer ID signing and notarization, so that users can install it without disabling System Integrity Protection.

Hector is meant to be built and used by anyone from source, so it does not depend on either. It uses only interfaces that work for an unsigned or ad-hoc signed binary:

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
│ Hector.app (SwiftUI)    │      │ hector (CLI)              │
│ connections · map · rules│      │ connections · geo · rules  │
└────────────┬─────────────┘      └─────────────┬──────────────┘
             │ links                            │ links
             ▼                                  ▼
┌────────────────────────────────────────────────────────────────┐
│ HectorCore                                                    │
│  Collector ── SocketCollector: pids → fds → socket_fdinfo      │
│  GeoIP ────── GeoIPDatabase (sorted ranges, binary search)     │
│               GeoIPUpdater (monthly DB-IP download)            │
│  Rules ────── Blocklist (JSON) → RuleCompiler → CompiledBlock- │
│               list → PFAnchor (ruleset, tables) + HostsFile    │
│               HostsListCatalog · HostsListParser · Downloader  │
└────────────────────────────────────────────────────────────────┘
             │ blocklist as JSON over a Unix socket
             ▼
┌──────────────────────────┐
│ hectord (root)          │──► pfctl -a com.apple/250.Netbite …
│ applies, verifies, rolls │──► /etc/hosts managed section
│ back                     │
└──────────────────────────┘
```

- **HectorCore** has no UI and no privileged code. Most of it is unit tested.
- **hector** is the command-line front end. It is also the reference client while the app is being built.
- **Hector.app** is a SwiftUI app with the connections list, the world map, the details panel and the blocklist editor. The design mockup covers both screens.
- **hectord** is the only component that runs as root. It is deliberately small: it receives a blocklist, compiles it with HectorCore, writes the files and runs `pfctl`.

## Collector

`SocketCollector.snapshot()` takes a couple of milliseconds (1.5 ms measured as a normal user on an M-series Mac), cheap enough to poll every second:

1. `proc_listallpids` lists the processes.
2. For each pid, `proc_pidinfo(PROC_PIDLISTFDS)` lists its file descriptors. It fails with `EPERM` for processes of other users unless we run as root; those are counted, not hidden.
3. For each socket descriptor, `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` returns `socket_fdinfo`. Hector keeps TCP and UDP sockets of the IPv4 and IPv6 families.
4. Addresses are normalized: IPv4-mapped IPv6 becomes IPv4, and the interface index the kernel embeds in link-local addresses is cleared.
5. The executable path is mapped to its **outermost** `.app` bundle, so helper processes group under the app the user recognizes.

### Known limits

- **Host names.** A socket only knows the IP address. Reverse DNS (`--resolve`) returns PTR records, such as `fra16s50-in-f4.1e100.net`, not the name the app asked for. Attributing real names needs a view of DNS answers: see the roadmap.
- **Traffic volume.** Byte counters per connection are not exposed by libproc. `nettop` gets them from the private NetworkStatistics framework; that is planned as an optional source.
- **GeoIP load time.** Parsing the 700,000-line CSV takes about 1 s. The app loads it once at launch; a compact binary cache is planned so the CLI starts instantly too.
- **Short-lived connections** that open and close between two snapshots are missed. Polling every second catches most of them.

## Blocking

### pf anchor

The stock `/etc/pf.conf` of macOS contains `anchor "com.apple/*"`. Hector loads its rules into the sub-anchor `com.apple/250.Netbite`, so:

- `/etc/pf.conf` is never modified, and macOS updates cannot overwrite our rules;
- `pfctl -a com.apple/250.Netbite -F all` removes every Hector rule at once.

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
- pf is enabled with `pfctl -E`, which is reference-counted, so Hector does not turn pf off for other software that also uses it.

### /etc/hosts

Domains go to a section delimited by markers. `HostsFile.render` replaces only that section and leaves every other line byte-for-byte identical. Each domain points to `0.0.0.0` and `::`. After writing, the DNS cache is flushed.

Limits of this approach, documented in the UI as well:

- `*.example.com` cannot be expressed in a hosts file; only the apex is blocked and a warning is shown.
- Apps that use their own DNS-over-HTTPS resolver (some browsers) bypass `/etc/hosts`. Blocking the IP or the country still works for them.

### Hosts lists

Subscribed lists (`Blocklist.hostsLists`, identifiers of the built-in `HostsListCatalog`) add their domains to the same managed section, after a `# hosts lists` comment line, so personal domains and list domains stay apart while flush and uninstall keep working unchanged.

| List | Source | Format | Size |
|---|---|---|---|
| StevenBlack Unified | `raw.githubusercontent.com/StevenBlack/hosts/master/hosts` | hosts (`0.0.0.0 name`) | ~72,000 domains, 2.2 MB |
| EasyPrivacy | `raw.githubusercontent.com/hectorm/hmirror/master/data/easyprivacy/list.txt` | one name per line | ~43,000 domains, 0.9 MB |

EasyPrivacy itself is an Adblock Plus filter list; hMirror, the source of the hBlock project, extracts the domains of its whole-domain rules daily. Rules that only match a path or a third-party context cannot be expressed in a hosts file and are not in it. The two lists overlap by about 1,700 domains.

Design:

- **The helper downloads, the app sends identifiers.** Lists hold ~100,000 domains, far beyond the 5,000 rules and 4 MB a request may carry. The helper fetches the lists from the catalog's fixed URLs, as it does for the GeoIP database, so requests stay small and a non-root process cannot inject a crafted domain set. See [SECURITY.md](../SECURITY.md#hosts-lists) for the bounds.
- **Parsing.** `HostsListParser` accepts hosts lines whose address is a sink (`0.0.0.0`, `127.0.0.1`, `::`, `::1`) and plain one-name lines; comments, blank lines, CRLF and a byte order mark are handled; international names become punycode (`IDNA`, `Punycode`). Redirections, reserved and protected names are skipped and counted, malformed lines are dropped and counted. `HostsListDownloader.validate` refuses a list that is too small or too large.
- **Storage.** The helper keeps a validated copy of each list (one name per line) and a state file (domain count, last download, last check, last error, ETag, Last-Modified) in `/Library/Application Support/Hector/lists`. A failed download keeps the last good copy.
- **Updates.** When a blocklist with a new list is applied, the helper downloads it before applying (a failure is reported and the rest applies). Afterwards the server loop looks every 15 minutes for lists checked more than a week ago (or 6 hours after a failure) and refreshes them in the background with conditional requests; nothing is downloaded at boot. "Update Now" in the app and `hector lists refresh` force a check.
- **Compiling.** `RuleCompiler.compile(_:geo:lists:)` merges the subscribed lists, removes the personal domains and duplicates, checks every name again, and caps the total at 400,000. `CompiledBlocklist.listDomains` and `listDomainCounts` keep the lists apart from `hostsDomains`; `HelperStatus` reports `listDomainCount` and a `HostsListState` per list.
- **Compatibility.** Old blocklist files have no `hostsLists` key and decode with none; status replies from an older helper have no `hostsLists`, and the app then offers to update the helper.

Trade-offs of /etc/hosts at this size:

- Each domain is written twice (`0.0.0.0` and `::`), like personal rules, so that IPv6 lookups fail fast as well: ~110,000 domains are ~220,000 lines, about 6 MB. Rendering and comparing the file takes well under a second; it is rewritten only when its content changes.
- After each write the helper runs `dscacheutil -flushcache` and `killall -HUP mDNSResponder`; mDNSResponder then reloads the whole file. StevenBlack's file is widely used this way on macOS, but resolution latency and mDNSResponder's memory with both lists have to be measured on a real Mac (see NEXT_STEPS). If needed, list entries can drop the `::` line to halve the file.
- Hosts files block exact names only: subdomains not listed are not blocked, and apps with their own DNS-over-HTTPS resolver bypass the file.

### Safety rails

`RuleCompiler` refuses:

- networks wider than /8 (IPv4) or /16 (IPv6): a typo such as `/2` would cut the Mac off the internet;
- loopback, private, link-local, CGNAT and multicast ranges.

Country blocking is **opt-in**: `Blocklist.blockedCountries` is empty by default.

## Privileged helper

`hectord` is the only component that runs as root. Without a developer account, `SMAppService` daemons and `SMJobBless` cannot be used in a distributable way, so it installs itself:

1. The app runs `Hector.app/Contents/Helpers/hectord install` through `do shell script … with administrator privileges`; macOS shows its own password prompt. `install` copies the binary to `/Library/PrivilegedHelperTools/io.github.0xrd.hectord`, writes a LaunchDaemon plist and bootstraps it.
2. The helper listens on `/var/run/io.github.0xrd.hectord.sock`, mode 0660, owner root, group admin, and also checks the peer with `getpeereid`: only administrators can talk to it.
3. The protocol is one line of JSON per request (`status`, `apply(Blocklist, authorization)`, `flush(authorization)`, `refreshHostsLists(authorization)`, `snapshot`, `processes`, `backgroundTasks`) and one line of JSON in reply, at most 4 MB and within 5 s. Types are in `HectorCore/Helper`.
4. Changing the firewall needs more than the admin group: the client obtains the Authorization Services right `io.github.0xrd.hector.modify-firewall` (administrator password, remembered five minutes) and sends its external form; the helper checks it without interaction. Root clients are exempt.
5. On `apply`, the helper recompiles the blocklist itself with HectorCore: nothing compiled by the client is trusted. It writes the pf files under `/Library/Application Support/Hector/pf`, loads the anchor, and restores the previous files if `pfctl` fails. It downloads its own copy of the GeoIP database when a country is blocked, and of every subscribed hosts list.
6. pf rules do not survive a reboot. The helper stores the applied blocklist and applies it again when launchd starts it.
7. pf is enabled with `pfctl -E`, which returns a reference token; `flush` releases it with `pfctl -X`, so Hector never disables pf for other software. If pf has no main ruleset at all, the stock `/etc/pf.conf` is loaded so that `anchor "com.apple/*"` is evaluated.
8. Files are written as root through `SecureFiles` (no symlink followed, root-owned, temp file then rename) and every log line is sanitized. See [SECURITY.md](../SECURITY.md) for the threat model.
9. `hectord uninstall` flushes every rule, removes the managed `/etc/hosts` section, unloads the daemon and deletes its files.

`hectord serve --dry-run DIR` runs the whole flow without root: paths live under `DIR` and commands are only logged. This is how the helper is tested outside a VM.

## Distribution

Releases are built by GitHub Actions from a tag: a universal (Apple silicon and Intel) `Hector.app`, ad-hoc signed, zipped with `ditto`, published with its SHA-256.

Without notarization, Gatekeeper blocks the first launch of a downloaded app. Users allow it once in System Settings → Privacy & Security → Open Anyway, or remove the quarantine attribute. Building from source avoids the prompt entirely.
