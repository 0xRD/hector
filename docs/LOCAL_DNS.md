# Local DNS resolver ("Hector as a local Pi-hole")

Design for the roadmap item [Next feature: Hector as a local Pi-hole](ROADMAP.md#next-feature-hector-as-a-local-pi-hole). Status: **design, with the pure core code written and tested** (`Sources/HectorCore/DNS`, `Sources/HectorCore/Rules/AdblockListParser.swift`). Nothing here runs as root or changes the system yet.

Facts marked *checked* were observed on the owner's Mac (macOS 26.6.2, Darwin 25.6, Command Line Tools 27) on 2026-10-04 or fetched from the source that day. Facts marked *to verify* are reasoned from documentation or memory and must be checked before the step that depends on them.

## Contents

1. [Goals and non-goals](#goals-and-non-goals)
2. [Why a resolver](#why-a-resolver)
3. [Architecture](#architecture)
4. [Pointing macOS at the resolver](#pointing-macos-at-the-resolver)
5. [Failure mode: never cut the Mac off](#failure-mode-never-cut-the-mac-off)
6. [Upstream forwarding](#upstream-forwarding)
7. [Query log and per-app attribution](#query-log-and-per-app-attribution)
8. [Wildcard blocking and allowlist precedence](#wildcard-blocking-and-allowlist-precedence)
9. [More lists](#more-lists)
10. [Memory and latency budget](#memory-and-latency-budget)
11. [Threat model additions for SECURITY.md](#threat-model-additions-for-securitymd)
12. [Phased plan](#phased-plan)
13. [Open questions](#open-questions)
14. [What could not be verified](#what-could-not-be-verified)

## Goals and non-goals

Goals:

- Block a domain **and all its subdomains** (`||example.com^`), which /etc/hosts cannot express.
- A **query log**: which name was asked, blocked or allowed, by which rule, and by which app when that can be known; counts per day.
- An **allowlist** that wins over lists, one click from the log.
- **More lists**, including the DNS-native ones (OISD, HaGeZi, AdGuard DNS filter, 1Hosts) whose entries mean "this name and below".
- **Safety first**: a crash or a hang of the resolver falls back to the normal DNS within seconds. The Mac is never left without name resolution because of Hector.
- Everything works **without a paid Apple Developer account** and without a Network Extension.

Non-goals for this feature:

- Serving other devices on the LAN (a later, opt-in step: it changes the threat model).
- Validating DNSSEC (answers pass through unchanged, AD bit included).
- Blocking apps that bypass the system resolver with their own DNS over HTTPS. pf rules for IPs and countries still apply to them.

## Why a resolver

Today (0.4.1) lists go to the managed section of /etc/hosts. That works and is measured: 43,112 list domains, 6 ms for a blocked name, 30 to 50 ms for normal names. Its limits:

| | /etc/hosts | Local resolver |
|---|---|---|
| `example.com` and every subdomain | no (each subdomain listed separately) | yes |
| Lists in adblock or wildcard syntax | partly (the listed names only, which under-blocks) | yes |
| Query log | no | yes |
| Per-app log | no | partly, see [attribution](#query-log-and-per-app-attribution) |
| Allowlist over lists | only by removing entries | yes, a layer checked first |
| Size | ~110,000 domains = ~220,000 lines, 6 MB, reloaded by mDNSResponder on every change | ~8 MB in an unprivileged process for 358,000 names (measured, below) |
| Failure mode | none: a file | a process that can crash, so a watchdog is required |

*Checked:* on the owner's Mac, with 113,625 domains in /etc/hosts (each written twice), `ps -o rss` reports 394,544 KB for mDNSResponder. There is no baseline without lists yet, so this is not proof that the hosts file costs that much, but it is a strong hint and the first thing to measure (see [budget](#memory-and-latency-budget)).

## Architecture

```
            apps ──► mDNSResponder (system cache, .local, supplemental resolvers)
                          │  UDP/TCP to the "primary" DNS server: 127.0.0.1:53, [::1]:53
                          ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ hectord resolve        (child of the helper, uid/gid nobody, own sandbox)     │
│  fds 3–6: UDP 127.0.0.1:53, UDP [::1]:53, TCP 127.0.0.1:53, TCP [::1]:53     │
│  DNSMessage parse ─► DomainPolicy decision ─► DNSAnswers (blocked)            │
│                                         └──► forward: original servers / DoH  │
│  query log ring (memory) ◄── ResolverAttribution ◄── stdin: `log stream`      │
│  fd 7: control socket (policy updates, upstreams, health, log reads)          │
└───────────────────────────────────────────────────────────────────────────────┘
                          ▲ spawn, sockets, policy, upstreams       │ health, counters
┌─────────────────────────┴─────────────────────────────────────────▼───────────┐
│ hectord (root)                                                                │
│  binds port 53 · compiles the policy · owns the DNS override · watchdog       │
│  starts `/usr/bin/log stream` for mDNSResponder and pipes it into the child   │
└───────────────────────────────────────────────────────────────────────────────┘
                          ▲ Unix socket, admin only (existing protocol + dns requests)
                    Hector.app / hector CLI
```

### Who does what

- **Root (hectord)** keeps the small set of things only root can do: bind port 53, read the lists in `/Library/Application Support/Hector/lists` (0700), change the system DNS configuration, and supervise. It never parses a DNS packet, a list or a log line.
- **The child (`hectord resolve`)** does everything that touches untrusted bytes: queries from any local process, answers from the network, mDNSResponder's log. It drops to `nobody` exactly like the download children (`Unprivileged.dropPrivileges`: `setgroups`, `setgid`, `setuid`, then checks that `setuid(0)` fails) before reading a single byte, and runs under its own sandbox profile (to write with the hectord sandbox work: network out to the configured upstreams only, no file system beyond its inherited descriptors).
- **The app and the CLI** talk to root only, through new requests on the existing socket (`dnsStatus`, `dnsLog`, `setDNS(enabled:…, authorization)`), which root relays to the child over the control socket.

### Handing the sockets over

Ports below 1024 need root. Root creates the four sockets (`SO_REUSEADDR`, bound to the loopback addresses only, `IPV6_V6ONLY` on the IPv6 ones, TCP in listen state, all `O_NONBLOCK` and close-on-exec) and passes them to the child at fixed descriptor numbers, in the spirit of launchd and systemd socket activation.

Foundation's `Process` cannot do this: it passes standard input, output and error only. The child is therefore started with `posix_spawn` and `posix_spawn_file_actions_adddup2` for descriptors 3 to 7 (four listeners and one end of a `socketpair` for control), with `POSIX_SPAWN_CLOEXEC_DEFAULT` so nothing else leaks, the same fixed environment as `Unprivileged.runChild`, and standard input connected to the `log stream` pipe. The child checks at start that descriptors 3 to 6 are sockets of the expected family, type and loopback address (`getsockname`), and refuses to run otherwise.

Alternative kept in reserve: send the descriptors over the control socket with `SCM_RIGHTS`. It allows replacing a socket without a restart, at the cost of more code. Not needed at first.

Before binding, root checks that nothing else listens on port 53 (`EADDRINUSE` on bind is the check). Other DNS software (dnsmasq from Homebrew, a VPN client) is then reported, and Hector stays in /etc/hosts mode.

### Getting the policy to the child

The child cannot read the root-only list folder, and should not: it only needs the compiled result. Root builds the four inputs of `DomainPolicy` (allowlist, personal rules, list exceptions, lists) with the existing `RuleCompiler` checks and writes them to a private file (names, one per line, with a flag for "with subdomains"), opens it read-only and passes the descriptor over the control socket with `SCM_RIGHTS` (or at spawn time). The child reads it, parses every name again (`DomainPattern`), builds the `DomainSet`s (0.1 s for 358,000 names) and swaps the policy atomically. A bad file never replaces a good policy.

### What happens to /etc/hosts

When the resolver is on, **list domains leave /etc/hosts** (otherwise mDNSResponder answers them from the file, the resolver never sees them, the log stays empty and mDNSResponder keeps the memory cost). **Personal domains stay in /etc/hosts as well**, so personal rules still apply during a fallback. Lists are not put back into /etc/hosts during a short fallback (rewriting 6 MB and reloading mDNSResponder takes seconds and is what we want to avoid); the status shows "Lists paused: resolver restarting". After repeated crashes the resolver is switched off and the lists go back to /etc/hosts. See [open questions](#open-questions).

## Pointing macOS at the resolver

macOS does not read /etc/resolv.conf for resolution: mDNSResponder takes its configuration from configd (SystemConfiguration). Candidates, all usable **without a developer account** because they only need root, which the helper has:

| Mechanism | Scope | Survives a helper crash? | Survives reboot? | Verdict |
|---|---|---|---|---|
| `/etc/resolver/<domain>` files (`man 5 resolver`) | one domain (supplemental) | yes | yes | Cannot replace the default resolver. Useful for testing: `/etc/resolver/hector.test` sends only `*.hector.test` to the resolver, even on a high port (`port` keyword, *checked* in the man page). |
| `networksetup -setdnsservers <service> 127.0.0.1 ::1` (SCPreferences `Setup:` DNS, persistent) | default resolver of one network service | **yes, which is the problem** | **yes** | Rejected as the main mechanism: a crashed helper leaves the Mac pointed at a dead resolver until someone undoes it. Kept as a documented manual fallback only. |
| Dynamic store **temporary value** (`SCDynamicStoreAddTemporaryValue`) for the primary service's DNS entity | default resolver | **no: configd removes a temporary value when the session that created it ends**, crash included | no | **Chosen**, to verify in phase 0 (which key IPMonitor honors, and behaviour on network changes). |
| Configuration profile with a DNSSettings payload | default resolver, encrypted DNS only | yes | yes | Rejected: DoH/DoT only, so it needs a TLS server on localhost with a certificate the system trusts; the user installs it in System Settings. |
| `NEDNSProxyProvider`, `NEDNSSettingsManager` | | | | Out of scope: Network Extension entitlement, paid account. |

*Checked* (read-only `scutil`): the DHCP-provided servers live in `State:/Network/Service/<primary>/DNS` (owned by IPConfiguration); `Setup:/Network/Service/*/DNS` is empty unless the user typed servers in System Settings; configd publishes the merged result in `State:/Network/Global/DNS`, where for the same service a `Setup:` entity overrides the `State:` one.

**Proposed mechanism (to verify in phase 0):** root opens an `SCDynamicStore` session and adds a **temporary** `Setup:/Network/Service/<primary service ID>/DNS` with `ServerAddresses = [127.0.0.1, ::1]` and the original `SearchDomains`. Because it is temporary, it disappears when hectord exits or crashes; because it lives only in the dynamic store, it never reaches `/Library/Preferences/SystemConfiguration/preferences.plist` and does not survive a reboot. The original servers remain readable underneath in `State:/Network/Service/<primary>/DNS`, which is where upstreams come from. Root watches the store (`State:/Network/Global/IPv4`, `State:/Network/Service/*/DNS`, `Setup:/Network/Service/*/DNS`) and moves the override when the primary service changes (Wi-Fi to Ethernet, a VPN). Phase 0 must answer:

1. Does IPMonitor honor a `Setup:` DNS entity that exists only in the dynamic store? (Tunnelblick-style scripts are reported to write both `State:` and `Setup:` keys of the primary service, which suggests yes.) If not, the alternative is a temporary value on the `State:` key, which IPConfiguration may overwrite on lease renewal; root would then re-assert it on change notifications, failing open in between.
2. Does a preference change (the user edits Wi-Fi settings) replace the temporary `Setup:` value? If so, that is a fail-open event, which is acceptable; root re-applies after a health check.
3. What mDNSResponder does with `127.0.0.1` and `::1` together, and how quickly it switches servers when one stops answering (it should, as with any pair of servers).

Supplemental resolvers stay untouched: `.local` (mDNS), the reverse zones, VPN split-DNS domains. Only the default resolver changes.

**Undo in one step:**

- In the app: the "Local resolver" switch; in the CLI: `hector dns off`. Root removes the temporary value and stops the child; lists go back to /etc/hosts.
- Without Hector's UI: `sudo launchctl kickstart -k system/io.github.0xrd.hectord` or `sudo killall hectord`; the temporary value disappears with the process. A reboot also clears it.
- `hectord uninstall` removes it as part of the flush.

## Failure mode: never cut the Mac off

The rule: **if in doubt, give DNS back to the system**. Root supervises; the child never decides alone whether the Mac uses it.

1. **Child exits** (crash, `SIGKILL`, a failed privilege drop): root learns it from a `DISPATCH_SOURCE_TYPE_PROC` exit event and removes the override at once, before restarting anything. mDNSResponder then talks to the original servers directly, as before Hector.
2. **Child hangs** (deadlock, `SIGSTOP`, a loop): root sends a probe every 5 seconds, a real DNS query over UDP to 127.0.0.1:53 for a reserved name (`<random>.probe.hector.invalid`, answered by the child itself without forwarding). Two failures in a row (1 s timeout each) remove the override and kill the child.
3. **Upstream is down but the network is up** (DoH provider blocked, captive portal): the child reports upstream health on the control socket. When every upstream fails for 10 seconds, root removes the override; mDNSResponder then uses the original servers, which is exactly what a captive portal needs. With plain forwarding to the original servers this case mostly disappears, since the resolver uses the same servers mDNSResponder would.
4. **Restart policy:** after a fallback, restart the child with backoff (1 s, 5 s, 30 s, then every 5 min). The override is applied again only after a successful probe of the new child. Three crashes within 10 minutes switch the resolver off until the user turns it on again, lists go back to /etc/hosts, and the app says why.
5. **Root crashes:** configd drops the temporary value with the session (point to verify in phase 0). launchd restarts hectord, which does not apply the override before the child passes a probe.
6. **Boot, sleep and wake:** nothing is applied before the child is healthy. On wake and on every network change, upstreams are re-read and the probe runs before the override is re-asserted.
7. **Loops:** `127.0.0.1`, `::1` and any address of this Mac are never accepted as upstreams. The child refuses queries from its own sockets.

Test plan for this section (a VM is preferable, the owner's Mac acceptable): `kill -9` the child; `kill -STOP` the child; `kill -9` hectord; switch Wi-Fi networks; plug Ethernet; join a captive portal; connect a VPN; sleep for an hour; unplug the network; and after each one, `scutil --dns` shows the original servers or 127.0.0.1 within 10 seconds and `dscacheutil -q host -a name apple.com` answers.

## Upstream forwarding

**Default: the user's original DNS servers**, read from `State:/Network/Service/<primary>/DNS` (or the user's own `Setup:` servers), so Hector changes nothing about who sees the queries.

- Each upstream query goes out from a fresh UDP socket `connect`ed to `server:53` (the kernel then delivers datagrams from that address and port only, and picks a random source port), with a **new random message ID** (`SecRandomCopyBytes`); the original ID is restored in the answer. An answer is accepted only if `DNSMessage(bytes:)` parses it and `isResponse(to:)` holds (ID, opcode, question with case-insensitive name).
- The client's query is forwarded unchanged otherwise (EDNS, DO and CD bits). The answer is forwarded as the bytes received, never re-encoded, so record types Hector does not decode pass through intact.
- A truncated answer (TC) is retried over TCP to the same server. TCP queries from mDNSResponder are forwarded over TCP.
- 2 s per server, then the next; at most 512 queries in flight; beyond that new queries get SERVFAIL. No cache at first: mDNSResponder caches already, and a cache is where poisoning lives.
- **CNAME inspection** (later step): if an allowed name's answer holds a CNAME to a blocked name (CNAME cloaking of trackers), answer it as blocked. `DNSRecordData.name` already decodes CNAME targets.

**Optional: DNS over HTTPS** (RFC 8484, `POST` with `application/dns-message`), off by default because it sends every name to a third party. It runs in the child with an ephemeral `URLSession`. The bootstrap problem (resolving the DoH server's name would loop through Hector) is avoided by using IP literals. *Checked:* `https://1.1.1.1/dns-query` (Cloudflare), `https://9.9.9.9/dns-query` (Quad9), `https://8.8.8.8/dns-query` (Google) and `https://94.140.14.140/dns-query` (AdGuard, unfiltered) answer a DoH GET with HTTP 200 and `application/dns-message`, and each certificate has the IP address in its subjectAltName. Built-in choices only, like the list catalog: no custom URL (a URL field would let any process holding the authorization make the resolver talk to an arbitrary host). "Strict" mode (no fallback to plain DNS when DoH fails) is a later option; the default falls back, so captive portals keep working.

## Query log and per-app attribution

### What the resolver can see by itself

Every query arriving on 127.0.0.1:53 has a source address and port. In the normal path that source is **mDNSResponder** (user `_mdnsresponder`): apps call `getaddrinfo`, Network.framework or dns_sd, mDNSResponder answers from its cache or asks the primary server. **The query itself carries nothing about the app.** Two consequences:

- A name already in mDNSResponder's cache never reaches the resolver. Counts seen by the resolver are a lower bound of lookups (blocked answers have a short TTL, 2 s like Pi-hole's default, to keep them close).
- Tools that read /etc/resolv.conf and talk to the primary server themselves (`dig`, `nslookup`, some cross-platform runtimes) reach the resolver from their own socket. Their source port identifies them: root already lists every process's sockets each second (`SocketCollector`), so the child can ask root which process owns a local UDP port. This is cheap and exact, but only covers these tools.

### mDNSResponder's log names the client

*Checked:* mDNSResponder logs every lookup at the default level, readable by an administrator without root (`/usr/bin/log show` or `stream`; this is the same channel `SensorIndicatorLog` already uses for Control Center). Four message shapes matter (values made up):

```
[R1001] DNSServiceQueryRecord START -- qname: <mask.hash: '…'>, qtype: AAAA, flags: 0x15000, interface index: 0, client pid: 4242 (curl), name hash: 818588a2
[R1002] DNSServiceGetAddrInfo START -- hostname: <mask.hash: '…'>, protocols: 3, flags: 0x1D000, interface index: 0, client pid: 4243 (python3), name hash: 5ba3fe1f
[R1003] getaddrinfo start -- flags: 0xC000D000, ifindex: 0, protocols: 0, hostname: <mask.hash: '…'>, options: 0x8 {use-failover}, client pid: 4244 (Some App)
[R1003->Q64907] Question assigned DNS service 20
```

The name is masked with a salted hash that Hector cannot compute. Two other keys survive:

1. **`name hash` is FNV-1a (32 bits) of the lowercased name in wire form** (length bytes, labels, final zero). *Checked* against two real lookups (`www.wikipedia.org` → `818588a2`; `www.example.org` looked up as `WWW.Example.ORG` → `5ba3fe1f`). The resolver computes it for every query (`DNSName.mDNSResponderHash`). Only the dns_sd shapes carry it: `DNSServiceQueryRecord` and `DNSServiceGetAddrInfo`, which is what `getaddrinfo(3)` users go through (command-line tools, BSD-socket code). In a 10-minute sample: curl, git, gh, Python, dscacheutil.
2. **`[R…->Q…] Question assigned`** links the request to a number up to 65,535 (*checked*: the largest seen in a sample was 65,512). It is very likely the 16-bit message ID mDNSResponder puts in the query it sends upstream (`mDNSVal16(q->TargetQID)` in mDNSResponder's source, from memory). *To verify* with a packet capture on lo0 once the resolver runs in phase 2 (root, by the owner): if confirmed, the resolver looks up the request, then its client, by the ID of the query it received. This is the only key for the Network.framework shape (`getaddrinfo start` in the `com.apple.mdns:dnssd_server` category), which most apps use: in the same sample OneDrive, WhatsApp, WebKit, Spotlight, cloudd, trustd, syspolicyd.

`MDNSResponderLog` parses these lines and `ResolverAttribution` joins them to queries (both written and tested). Safety rules built in:

- A line counts only if its `processImagePath` is `/usr/sbin/mDNSResponder` (any process can log under any subsystem name).
- Lines whose name is **not** masked are refused: with private data logging turned on, the name is chosen by the app and could contain `, client pid: 1 (Safari)`. Fields are read only after the masked name; the PID comes before the process name, so the name cannot fake it.
- A match by message ID is checked against the request's name hash when there is one (IDs are 16 bits). Two candidate clients give "unknown", never a guess.
- Process names are the 15-character short names the process chose: a hint for display. The identity is the PID, resolved to the executable and its signature through the process collector at the time of the event (PIDs are reused).

Where the log is read: an unprivileged `nobody` cannot read the unified log, and root should not parse it. Root therefore starts `/usr/bin/log stream --style ndjson --predicate <MDNSResponderLog.predicate>` (fixed path, fixed arguments, the lifeline pattern `SensorIndicatorWatcher` uses so it dies with its parent) and connects its standard output to the child's standard input. Root never reads a byte of it.

What this gives, honestly:

| Lookup | Reaches the resolver | App known |
|---|---|---|
| dns_sd / `getaddrinfo(3)`, cache miss | yes | yes, by name hash (*checked* key) |
| Network.framework, cache miss | yes | yes if the Q = message ID hypothesis holds, else no |
| Any client, cache hit | no | the dns_sd shape still logs a START with the name hash, so a name the resolver has seen recently can be counted for that app; Network.framework cache hits cannot |
| `dig`-like tools querying 127.0.0.1 directly | yes | yes, by source port |
| Apps with their own DoH | no | no (pf and the connection list still see them) |
| Delegated lookups (a daemon resolving for an app) | yes | the daemon, unless mDNSResponder logs a delegate PID (not seen yet) |

Fallback when no key matches: **connection correlation**. The resolver knows which addresses it returned for which name; when the collector sees a process connect to one of those addresses within a few seconds, the name is attributed to that process ("probably"). This only works for allowed names. None of this is an API, and macOS may change the messages; attribution then degrades to "unknown app" without affecting resolution.

### Storage and privacy

The log is the browsing history of every account on the Mac. It stays **in the child's memory** (a ring of the last 10,000 queries, about 2 MB) and is readable only through the helper socket, by administrators, like `snapshot`. Daily counts per name and per app may be persisted later (opt-in, 30 days, root-only file). Nothing leaves the Mac. The app shows names through `LogText.sanitized` and `DNSName.description`, which escapes bytes that are not printable ASCII.

## Wildcard blocking and allowlist precedence

Implemented in `DomainSet` and `DomainPolicy`:

- An entry is either **exact** (the name only) or **with subdomains** (the name and every name below it, on label boundaries: `doubleclick.net` covers `stats.g.doubleclick.net` but not `notdoubleclick.net`).
- What each source means:
  - hosts-format lists (StevenBlack, hMirror's EasyPrivacy, Peter Lowe's hosts file): exact, as they are written;
  - wildcard-domain lists (OISD `domainswild2`, HaGeZi `wildcard/*-onlydomains.txt`, 1Hosts `domains.wildcards`): with subdomains, as their headers say (*checked*: OISD "Entry: "example.com" should block access to "example.com" and "subdomain.example.com"");
  - adblock lists: `||name^` is with subdomains;
  - personal rules: `example.com` stays exact as today; `*.example.com` becomes the apex **and** its subdomains (today it blocks only the apex in /etc/hosts and shows a warning).
- **Precedence**, first match wins: (1) the user's allowlist, (2) personal rules, (3) exceptions inside lists (`@@||name^`), (4) lists. The allowlist wins over everything, as Pi-hole does. Within a layer the most specific entry is reported, so the log can say "blocked by `doubleclick.net` (OISD big)".
- **Never blocked**: reserved names and the hosts Hector downloads from are dropped when lists are parsed (`HostsListParser.isReserved`, `HostsListCatalog.protectedHosts`); names that are not plain host names (bytes other than letters, digits, `-`, `_`) are never matched and go upstream as they are.
- **Blocked answer**: `0.0.0.0` for A, `::` for AAAA, an empty answer for every other type (HTTPS, SVCB, MX…), with a 2-second TTL (`DNSBlockStyle.nullAddress`, Pi-hole's default "NULL" mode). NXDOMAIN is the alternative style. A null address makes apps fail at once without a "this name does not exist" entry in negative caches.
- Optional special names, off by default: `use-application-dns.net` answered NXDOMAIN (Firefox's canary that turns off its automatic DoH, so Firefox keeps using the resolver); iCloud Private Relay's `mask.icloud.com` and `mask-h2.icloud.com` (Pi-hole blocks them by default to keep Safari on the resolver; that is the user's call).

Adblock syntax supported (`AdblockListParser`): `||name^`, `@@||name^`, the `$important` modifier (accepted, no effect yet) and `$badfilter` (cancels the identical rule). Everything else is counted as unsupported and dropped: other modifiers (`$third-party`, `$client`, `$dnstype`, `$denyallow`…), `*` wildcards, regular expressions, paths, ports, IP rules (`||203.0.113.7^`, which AdGuard Home applies to answers), cosmetic rules, bare hosts lines. Honoring them half-way would block more or less than the list means. *Checked* on the real AdGuard DNS filter: 177,221 names and 11 exceptions kept, 948 rules unsupported and none invalid: 72 IP rules, the rest `$`-modified rules, regular expressions and wildcard patterns (of its 210 exceptions only 11 are plain `@@||name^`). One known difference: in AdGuard, `||name^$important` beats an exception; here the exception wins (3 rules in that list).

## More lists

All fetched on 2026-10-04 (*checked*: HTTP 200, first lines, entry counts, license files). Sizes are the downloaded body.

| List | URL | Format | Entries | Size | License |
|---|---|---|---|---|---|
| OISD small | `https://small.oisd.nl/domainswild2` | wildcard domains | 57,822 | 1.1 MB | GPL-3.0 (`github.com/sjhgvr/oisd/blob/main/LICENSE`) |
| OISD big | `https://big.oisd.nl/domainswild2` | wildcard domains | 244,268 | 4.9 MB | GPL-3.0 |
| OISD small / big, adblock | `https://small.oisd.nl/`, `https://big.oisd.nl/` | `||name^` | same | 1.3 / 5.6 MB | GPL-3.0 |
| HaGeZi Multi Light | `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt` | wildcard domains | 51,559 | 1.1 MB | GPL-3.0 |
| HaGeZi Multi Normal | `…/wildcard/multi-onlydomains.txt` | wildcard domains | 156,923 | 3.1 MB | GPL-3.0 |
| HaGeZi Multi Pro | `…/wildcard/pro-onlydomains.txt` | wildcard domains | 193,414 | 3.6 MB | GPL-3.0 |
| HaGeZi Threat Intelligence Feeds | `…/wildcard/tif-onlydomains.txt` | wildcard domains | 2,355,004 | 41 MB | GPL-3.0 |
| HaGeZi TIF medium / mini | `…/wildcard/tif.medium-onlydomains.txt`, `…/wildcard/tif.mini-onlydomains.txt` | wildcard domains | 671,282 / 191,609 | 12.4 / 3.5 MB | GPL-3.0 |
| HaGeZi, adblock syntax | `…/adblock/light.txt`, `multi.txt`, `pro.txt` (pattern; light and pro fetched) | `||name^` | same | | GPL-3.0 |
| AdGuard DNS filter | `https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt` | adblock with modifiers and exceptions | 179,843 lines (177,221 usable names) | 4.3 MB | GPL-3.0 |
| 1Hosts Lite | `https://raw.githubusercontent.com/badmojr/1Hosts/master/Lite/domains.wildcards` | wildcard domains | 102,259 | 2.0 MB | MPL-2.0 |
| 1Hosts Xtra | `…/Xtra/domains.wildcards` | wildcard domains | 786,172 | 12.7 MB | MPL-2.0 |
| Peter Lowe's list | `https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&mimetype=plaintext` (also `hostformat=hosts`, `adblockplus`) | one name per line | 3,551 | 59 KB | no formal license found; the site says to "feel free to combine this list with yours" |

Notes:

- HaGeZi's README recommends the jsDelivr mirror (`https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/light-onlydomains.txt`, *checked*, same content). Two hosts per list would need two protected hosts; raw.githubusercontent.com is already protected for the current lists, so the GitHub URLs are the simpler choice.
- 1Hosts no longer has a "Pro" variant: `o0.pages.dev/Pro/domains.wildcards` answers 404, and the `o0.pages.dev` Lite mirror was last modified on 2025-12-25 while GitHub's copy is from 2026-09-03. Use GitHub.
- HaGeZi TIF (2.4 M), TIF medium (0.67 M) and 1Hosts Xtra (0.79 M) exceed today's bounds (300,000 per list, 400,000 in total). TIF mini fits. Raising the bounds for the resolver is possible (8 MB per 358,000 names, measured) but is a decision for phase 5, with its own memory measurement.
- Peter Lowe's list is small and mostly contained in the others; keep it optional. Its license is unclear: ask the author or leave it out of the default catalog.
- Suggested defaults for resolver mode: HaGeZi Light or OISD small (both "don't break things" by design), with HaGeZi Pro and OISD big as stronger options. StevenBlack stays the default in /etc/hosts mode.

**Why the catalog is not extended yet.** `HostsListSource` has no notion of format, the downloader always uses `HostsListParser`, and the compiler writes every list name to /etc/hosts as an exact name. Adding a wildcard list today would silently under-block (OISD lists `000webhostapp.com` meaning every user site below it), and an adblock list would not parse at all. The catalog needs a `format: DomainListFormat` field (the enum exists: `hosts`, `wildcardDomains`, `adblock`), the child must call `format.parse`, the stored copy must keep exceptions and the subtree flag, and lists whose format needs the resolver must be hidden or marked "resolver only" while it is off. That is phase 5.

## Memory and latency budget

Measured now (temporary benchmark on the owner's Mac, real lists, optimized build `-O`; a debug build is 3 times slower to parse and 15 times slower to look up):

| What | Result |
|---|---|
| Parse OISD big (244,268 names, 4.9 MB) | 0.79 s |
| Parse AdGuard DNS filter (4.3 MB, adblock) | 0.70 s |
| `DomainSet` of OISD big + HaGeZi Pro (357,985 unique names) | 8.2 MB (about 23 bytes per name), built in 0.09 s |
| Lookup, half hits (`www.sub.` + listed name), half misses | 0.56 µs per lookup |

Budget for the child, to hold in phase 2 and 5:

- **Memory**: under 40 MB resident with 400,000 names and a full query log (8 to 10 MB of sets, 2 MB of log, the rest Swift and Foundation).
- **Latency added**: under 1 ms at the median for a forwarded query compared with mDNSResponder asking the same upstream directly; under 1 ms for a blocked answer.
- **CPU**: nothing measurable at rest; the policy rebuild (0.1 s) only on changes.

How to measure against /etc/hosts (phase 2, a `hector dns bench` command or a script):

1. Baseline in /etc/hosts mode with the current lists: mDNSResponder's resident memory (`ps -o rss= -p $(pgrep -x mDNSResponder)`), then the same **with lists removed** to know what the hosts file costs (the 385 MB above).
2. Latency through the system resolver, as apps see it: `getaddrinfo` for (a) 1,000 blocked list names, (b) 1,000 unique names that miss every cache (random labels under a domain that answers NXDOMAIN quickly, such as `<uuid>.example.com`), (c) 200 popular names twice (second pass from cache). `dscacheutil -flushcache` before each run. Report median, p95 and maximum.
3. The same three runs in resolver mode, plus the child's resident memory and mDNSResponder's.
4. Shadow mode first (phase 1): the resolver on a high port reached only through `/etc/resolver/hector.test`, so its own latency can be measured with `dig @127.0.0.1 -p <port>` before it carries real traffic.

## Threat model additions for SECURITY.md

Proposed text for a "Local resolver" section, to add when the resolver ships (phase 2):

- **A DNS parser listens on localhost.** Any process of any user on this Mac can send bytes to 127.0.0.1:53 and [::1]:53. The parser (`DNSMessage`) runs in a child that is `nobody`, sandboxed, with no file system access beyond its inherited sockets and policy descriptor. It checks bounds on every read, refuses compression pointers that do not point strictly backwards (no loops), names over 255 bytes, reserved label types and trailing bytes, never allocates by header counts, and is fuzzed. Port 53 is bound to the loopback addresses only; serving the LAN is a later, opt-in decision with its own review.
- **Root never parses DNS.** Root binds the sockets, starts and watches the child, and changes the DNS configuration. It reads nothing from the child but fixed-format control messages (health, counters, log pages for the app), bounded in size and decoded strictly.
- **Denial of service.** A local process can flood the resolver. Bounds: 512 queries in flight upstream, a fixed-size log ring, per-source rate limits; the worst case is slow DNS, and the watchdog gives DNS back to the system if probes fail. A flood cannot make Hector amplify traffic off the Mac beyond its in-flight limit.
- **Cache poisoning.** There is no resolver cache at first. Upstream answers must come from the server's address and port on a connected socket with a random source port and a fresh random 16-bit ID, must parse strictly, and must echo the question. That is the classic defence; it is not DNSSEC, which Hector passes through but does not validate. DoH, when chosen, adds TLS to an IP-literal endpoint.
- **DNS rebinding.** A public name answering with a private address lets a web page reach services on the LAN or on this Mac. The resolver can drop such answers for names outside local domains (like dnsmasq's `--stop-dns-rebind`). Off by default in the first version (it breaks some home setups); listed as an option. The blocked answer `0.0.0.0` is not a rebinding vector on macOS: connections to it fail.
- **Fail-open by design.** If the resolver crashes, hangs or loses its upstream, the system DNS comes back: the override is a temporary dynamic-store value that dies with the helper, and the watchdog removes it on any doubt. While it is off, list blocking is paused (personal rules stay in /etc/hosts). An attacker who can kill `nobody` processes (root, or the `nobody` user) can therefore turn list blocking off, never turn DNS off.
- **Who can change it.** Turning the resolver on or off, choosing upstreams and editing the allowlist need the same authorization right as `apply`. Upstreams are the system's own servers or built-in DoH endpoints, never a URL from a client.
- **The query log is sensitive.** It is every account's browsing history. It stays in memory, is served only to administrators over the helper socket, and is never written to disk unless the user turns on daily counts.
- **Log-based attribution is a hint.** Process names in mDNSResponder's log are chosen by the processes; lines are accepted only from mDNSResponder's executable and only with masked names. A malicious app can at most mislabel its own lookups.

## Phased plan

Each step is small enough for one review, keeps `main` releasable, and adds its own tests or a manual checklist.

**Phase 0 – questions answered on a real Mac (no code shipped).**

1. Read-only: compare `scutil --dns` and `State:/Network/Global/DNS` before and after the user sets DNS servers in System Settings, to confirm the `Setup:` over `State:` merge. *(Owner, a few minutes.)*
2. Prototype `SCDynamicStoreAddTemporaryValue` on `Setup:/Network/Service/<primary>/DNS` in a scratch tool run with sudo, pointing at a public resolver (not at Hector yet); check `scutil --dns`, then kill the tool and check the value is gone. Repeat with a network change and a sleep. *(Owner, in a VM if possible.)*
3. Confirm that `log stream` with `MDNSResponderLog.predicate` works from a LaunchDaemon (root) on macOS 15 and 26, and that the message shapes are the same on macOS 15.

**Phase 1 – the resolver without the system (no root needed).**

4. `hectord resolve --port 15353` as a plain process: UDP and TCP listeners, `DNSMessage` parsing, `DomainPolicy`, `DNSAnswers`, forwarding to a server given on the command line. Integration tests on a high port with real `DNSMessage` queries; `dig @127.0.0.1 -p 15353`.
5. Upstream hardening: connected sockets, random IDs, `isResponse(to:)`, TC to TCP, timeouts, in-flight limit. Tests with a fake upstream on another port (spoofed IDs, wrong question, truncation, silence).
6. Control protocol between root and child (policy file descriptor, upstream list, health, counters), with a strict decoder and fuzz tests.

**Phase 2 – supervised, opt-in, behind a switch.**

7. Root side: bind the four sockets, `posix_spawn` the child with descriptors 3–7, privilege drop, health probe, restart with backoff. Dry-run mode (`serve --dry-run`) runs the child on a high port.
8. The DNS override from phase 0, with the watchdog rules of [failure mode](#failure-mode-never-cut-the-mac-off). `hector dns on|off|status`. The failure test plan, run on a VM.
9. Lists move from /etc/hosts to the resolver when it is on; personal domains stay in both. Measurements from [the budget](#memory-and-latency-budget), written into ARCHITECTURE.md. Confirm the Q = message ID hypothesis with a capture on lo0.
10. SECURITY.md section from [above](#threat-model-additions-for-securitymd); sandbox profile for the child.

**Phase 3 – the log.**

11. Query ring in the child; `dnsLog` request through root; a log screen in the app (name, verdict, rule, list, time).
12. Attribution: `log stream` piped to the child, `ResolverAttribution`, source-port lookup for direct clients, connection correlation as a fallback. App names and icons through the process collector.

**Phase 4 – allowlist.**

13. `Blocklist.allowlist` (with a compatibility default for old files and old helpers), validated like rules; "Unblock" from the log; the allowlist also removes names from /etc/hosts in hosts mode, so it means the same thing in both modes.

**Phase 5 – more lists.**

14. `HostsListSource.format`; the download child calls `format.parse`; stored copies keep exceptions and the subtree flag; the compiler builds `DomainPolicy` inputs; lists that need the resolver are marked "resolver only".
15. Catalog entries from [the table](#more-lists), after a last check of URLs and licenses; bounds revisited with a memory measurement.

**Phase 6 – optional extras.** CNAME inspection; DoH upstreams; rebinding protection; the Firefox and Private Relay canaries; daily counts on disk; later, serving the LAN (off by default, separate review).

## Open questions

1. **The override key.** Does IPMonitor honor a temporary `Setup:` DNS entity in the dynamic store, and does it survive preference changes? (Phase 0.) If neither `Setup:` nor `State:` works cleanly, the fallback is the persistent `networksetup` route with a launchd-run restore, which is weaker on the failure side.
2. **Lists during a fallback. Decided (2026-10-04): pause.** Lists stop applying for the seconds a restart takes, and the status says so; /etc/hosts is not rewritten on a short fallback.
3. **VPNs. Decided (2026-10-04): step aside.** When a VPN becomes the primary service with its own DNS, Hector leaves its servers alone and says so in the status ("Paused: a VPN provides DNS").
4. **Personal block versus allowlist. Decided (2026-10-04): the allowlist wins**, over the user's own block rules too, and the UI must make that obvious: a blocked rule that an allowlist entry overrides is shown as "overridden by allowlist: <entry>", in the rule list and in the query log, and adding a block rule that an allowlist entry covers warns before saving.
5. **Blocked TTL.** 2 s keeps counts accurate and unblocking immediate, at the cost of more queries reaching the resolver. Measure.
6. **Peter Lowe's license.** No formal license found; ask before shipping it in the catalog.
7. **Bounds.** Keep 300,000 names per list and 400,000 in total for the resolver, or raise them (TIF medium, 1Hosts Xtra) once memory is measured?
8. **Who reads the log stream.** Proposed: root starts `log stream` and pipes it to the child unread. Alternative: the app reads it as the user (as for the camera) and joins it with log pages from the helper; less privileged plumbing, but attribution then exists only while the app runs.

## What could not be verified

- That `Q…` in `[R…->Q…] Question assigned` is the upstream DNS message ID (needs a packet capture, as root).
- Everything about the override mechanism: IPMonitor's handling of temporary `Setup:` or `State:` DNS values, behaviour on network changes and preference edits, and how fast mDNSResponder abandons a dead 127.0.0.1 (needs root; phase 0).
- The mDNSResponder message shapes on macOS 15 (only macOS 26.6 was observed), and whether delegated lookups log a delegate PID.
- Whether the 385 MB resident size of mDNSResponder comes from the 113,625-domain hosts file (needs a run without lists).
- Peter Lowe's list license.
- Whether `posix_spawn` descriptor inheritance interacts with the hardened runtime or the planned sandbox profile (expected not to, to check with the sandbox work).
