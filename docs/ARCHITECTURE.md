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
| Network (ASN) of an IP | DB-IP IP to ASN Lite CSV, in memory, optional | none |
| Block IPs, networks, countries | `pf` tables in an anchor | root |
| Block domains | managed section of `/etc/hosts` | root |
| Keyboard event taps | `CGGetEventTapList` (CoreGraphics) | none |
| Camera on or off | CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` | none |
| Audio input on or off, and which process records | Core Audio `kAudioDevicePropertyDeviceIsRunningSomewhere`, process objects | none |

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
│               ASNDatabase (same, compact, network names)       │
│               GeoIPUpdater, ASNUpdater (monthly DB-IP files)   │
│  Rules ────── Blocklist (JSON) → RuleCompiler → CompiledBlock- │
│               list → PFAnchor (ruleset, tables) + HostsFile    │
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
- **Network names.** The ASN file is larger than the country one. `ASNDatabase` keeps 12 bytes per IPv4 range and 48 per IPv6 range, merges adjacent ranges of the same network while loading, and stores each organization name once in a shared UTF-8 buffer; names become `String`s only for the address being looked up. The app loads it in the background after the countries, only if the user downloaded it; the CLI loads it only for `--asn` and `geo asn`. Names come from a downloaded file, so control and bidi formatting characters are stripped before they reach the screen or the terminal.
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

### Safety rails

`RuleCompiler` refuses:

- networks wider than /8 (IPv4) or /16 (IPv6): a typo such as `/2` would cut the Mac off the internet;
- loopback, private, link-local, CGNAT and multicast ranges.

Country blocking is **opt-in**: `Blocklist.blockedCountries` is empty by default.

## Privileged helper

`hectord` is the only component that runs as root. Without a developer account, `SMAppService` daemons and `SMJobBless` cannot be used in a distributable way, so it installs itself:

1. The app runs `Hector.app/Contents/Helpers/hectord install` through `do shell script … with administrator privileges`; macOS shows its own password prompt. `install` copies the binary to `/Library/PrivilegedHelperTools/io.github.0xrd.hectord`, writes a LaunchDaemon plist and bootstraps it.
2. The helper listens on `/var/run/io.github.0xrd.hectord.sock`, mode 0660, owner root, group admin, and also checks the peer with `getpeereid`: only administrators can talk to it.
3. The protocol is one line of JSON per request (`status`, `apply(Blocklist, authorization)`, `flush(authorization)`, `snapshot`) and one line of JSON in reply, at most 4 MB and within 5 s. Types are in `HectorCore/Helper`.
4. Changing the firewall needs more than the admin group: the client obtains the Authorization Services right `io.github.0xrd.hector.modify-firewall` (administrator password, remembered five minutes) and sends its external form; the helper checks it without interaction. Root clients are exempt.
5. On `apply`, the helper recompiles the blocklist itself with HectorCore: nothing compiled by the client is trusted. It writes the pf files under `/Library/Application Support/Hector/pf`, loads the anchor, and restores the previous files if `pfctl` fails. It downloads its own copy of the GeoIP database when a country is blocked.
6. pf rules do not survive a reboot. The helper stores the applied blocklist and applies it again when launchd starts it.
7. pf is enabled with `pfctl -E`, which returns a reference token; `flush` releases it with `pfctl -X`, so Hector never disables pf for other software. If pf has no main ruleset at all, the stock `/etc/pf.conf` is loaded so that `anchor "com.apple/*"` is evaluated.
8. Files are written as root through `SecureFiles` (no symlink followed, root-owned, temp file then rename) and every log line is sanitized. See [SECURITY.md](../SECURITY.md) for the threat model.
9. `hectord uninstall` flushes every rule, removes the managed `/etc/hosts` section, unloads the daemon and deletes its files.

`hectord serve --dry-run DIR` runs the whole flow without root: paths live under `DIR` and commands are only logged. This is how the helper is tested outside a VM.

## Privacy monitors

Both live in `HectorCore/Privacy`, run as the user, and need no entitlement, no helper and no permission prompt.

### Keyboard taps

`KeyboardTaps.list()` calls `CGGetEventTapList`, the public list of event taps the window server keeps (the source ReiKey uses), and keeps the taps whose event mask includes `keyDown`, `keyUp` or `flagsChanged`. For each tap it reports the tapping process (named through libproc), the tapped process (0 means every app), active or listen-only, enabled, and the tap location. The app adds the code signature of the tapping app.

Limits: the list says who installed a tap and what it asked for, not what it does with the keys. Keystrokes can also be read without a tap (an input method, `IOHIDManager` with Input Monitoring permission, a kernel or DriverKit extension, or Secure Input being off in a terminal); those are not listed. The list is a snapshot: a tap installed for a few seconds between two refreshes is missed.

### Camera and microphone

`CaptureDeviceReader` reads, without opening any device:

- cameras: every CoreMediaIO device and its `kCMIODevicePropertyDeviceIsRunningSomewhere` flag;
- audio inputs: every Core Audio device with an input stream and its `kAudioDevicePropertyDeviceIsRunningSomewhere` flag;
- which processes record: the Core Audio process objects (`kAudioHardwarePropertyProcessObjectList`, macOS 14), each with `kAudioProcessPropertyPID` and `kAudioProcessPropertyIsRunningInput`.

`CaptureDeviceMonitor` registers block-based property listeners (device lists, each device's "running somewhere" flag, the process list) on a private serial queue. The blocks only signal an `AsyncStream`; the state is read again on the main actor and compared with the previous one by `CaptureActivityTracker`, which produces the events (on, off, already on at start, app started or stopped recording). A read every 2 s catches what has no listener: an app starting to record while the microphone is already on. `stop()` removes every listener.

Limits, also stated in the app:

- **Which app uses a camera is not known.** CoreMediaIO says a camera runs, not for whom. The unified log carries hints (the subsystem `com.apple.cmio`, Control Center's indicator), but its messages change between macOS releases and are partly private; this is left for later research rather than shipped as a guess.
- **Microphone attribution is per Mac, not per device.** A process recording from any input is listed for every input device that is on. Hector does not read which device each process uses.
- **Headsets.** A USB or Bluetooth headset is often one device for both directions, so music playback alone sets its "running" flag. Such a device counts as recording only when some process records audio input.
- Virtual and aggregate devices (Zoom, Teams, Loopback, BlackHole) appear as audio inputs of their own.
- The log lives in memory while the app runs; nothing is saved.

## Distribution

Releases are built by GitHub Actions from a tag: a universal (Apple silicon and Intel) `Hector.app`, ad-hoc signed, zipped with `ditto`, published with its SHA-256.

Without notarization, Gatekeeper blocks the first launch of a downloaded app. Users allow it once in System Settings → Privacy & Security → Open Anyway, or remove the quarantine attribute. Building from source avoids the prompt entirely.
