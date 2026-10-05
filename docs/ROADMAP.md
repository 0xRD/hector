# Roadmap

## Top priority: lightweight and hardened

Hector is meant to run all the time and its helper runs as root, so these come before new features, and before the repository goes public.

- [ ] **Performance.** Measured on 2026-10-04 (M-series MacBook Pro, about 70 live connections): the app uses about 146 MB and 0 to 9% CPU while its window is open; the root helper uses about 2.5% CPU while idle, which is too much for a background service.
  - [x] The helper only works when asked; snapshots are now requested every second only while Connections is on screen (5 s on other screens, 10 s with no window), and app bundles are cached across snapshots
  - [x] The app: slower refresh when the window is hidden, minimized or on another screen (0% CPU hidden)
  - [x] Stop the camera and microphone poll when nothing needs it: it runs only while a microphone is running somewhere
  - [ ] Measure the helper again as root once updated
  - [x] Memory: the country and network databases are parsed once into a checked binary cache and mapped (76 + 33 MB → about 4 MB each, 1.5 s → 10 ms)
  - [ ] The window's own rendering (about 100 MB of graphics buffers): fewer blur layers, smaller map backing
  - [ ] Avoid re-rendering the whole window every second: diff the snapshot, update only what changed
  - [ ] A budget, checked before each release: idle helper 0% CPU and under 15 MB; app under 1% CPU with the window closed
- [ ] **Security of the root helper.** It must not be a way to escalate privileges, even for a malicious process of the logged-in user.
  - [x] Review of what 0.4 added to the helper (2026-10-04): `processes` no longer gives other users' arguments to administrators; see SECURITY.md
  - [x] Least privilege: hosts lists and the country database are downloaded and parsed by a child that drops to `nobody`; root re-checks the output (checked as root on 2026-10-04: EasyPrivacy, 43,112 domains)
  - [x] A sandbox profile for the helper (`sandbox_init`): writes only to its own files, /etc/hosts and /dev/pf, starts only pfctl, dscacheutil, killall, sfltool and itself (0.4.2; `hectord sandbox-profile`)
  - [x] Checked as root (2026-10-04, helper 0.4.2): "sandboxed", Apply with both lists (pf, downloads as `nobody`, /etc/hosts, cache flush), login items through sfltool; no sandbox denial in the system log. Not yet: Remove all rules and Uninstall
  - [ ] Authenticate the client beyond `getpeereid`: check the peer's code signature (audit token, designated requirement of Hector's own signature); needs a Developer ID to pin, so not before one exists (documented in SECURITY.md)
  - [x] Fuzz tests for the request decoder and the parsers that see outside data (hosts lists, DB-IP CSV and cache, `sfltool` output, blocklists)
  - [x] Hardened runtime for the helper and the CLI; every subprocess by absolute path with a fixed environment
  - [x] Update SECURITY.md with the result
  - [ ] Make the repository public

## Review of every screen on real data (2026-10-04)

Every screen looked at with the owner's real data (about 60 connections, 59 persistence items, 630 processes, 37 keyboard taps). Bugs first, then UI, then new features.

**Bugs and wrong information**
- [x] The sidebar footer and the Blocklists row say "0 rules · 0 countries" and "Blocking on" while 113,622 list domains are enforced: count the hosts lists
- [x] Connections: an app whose executable sits in a versioned folder is named after the version (`2.1.281` for Claude Code's `~/.local/share/claude/versions/2.1.281`): fall back to the parent folders' names when the file name looks like a version
- [x] Persistence: Hector's own helper is flagged "Ad hoc" like an unknown item: recognize `io.github.0xrd.hectord` (same signature as the running app) and say "Hector's helper"
- [x] Persistence: a launch agent whose plist is an empty dictionary (Google Keystone leaves these behind) shows two warnings: call it "Inert: empty file, launchd ignores it" and dim it
- [x] Persistence: a job that runs `/usr/bin/open` (DisplayLink) shows Apple's signature for `open`; resolve what it opens (`-a`, `-b` or a path in the arguments) and check that signature instead
- [x] Dates and numbers follow the system locale (French relative dates and spaces in numbers) inside an English interface: use English formatting until the app is localized

**UI**
- [x] Toolbar: the search field and the inspector button show on screens that have neither (Checkup, Blocklists, Camera & mic); hide them, or search what the screen shows
- [x] Inspector columns take a quarter of the window with "No item selected": start collapsed and open on selection, or show a summary of the screen instead
- [x] Persistence and Processes headers: "Check all with VirusTotal" and "Show Apple items" are cut or wrapped at the default width; move them to a toolbar menu or shorten
- [x] Processes: 630 rows, almost all Apple daemons: Apple's processes (SIP-protected folders) hidden by default behind an "Apple" switch, their parents kept dimmed in the tree
- [x] Processes and Persistence: a per-row "Check" link in the VirusTotal column (done as an opt-in: Settings → VirusTotal → Look up automatically); replace with automatic lookups for non-Apple items when a key is set (within the free quota), and show the score or "not checked"
- [x] Keyboard taps: 33 of 37 rows are DockDoor taps that are switched off; group by app ("DockDoor · 31 taps, 1 active"), hide switched-off taps by default, explain active vs listen-only
- [x] Camera & mic: "In use now" lists every device even when all are off; show what is on at the top and the devices in a compact list below; mark expected system clients (`corespeechd` for "Hey Siri") as such
- [x] Connections: one row per port and protocol for the same address (160.79.104.10 three times under one app); merge them into one destination with its ports
- [ ] Connections: most rows are bare IP addresses or cloud reverse names; names from DNS answers would fix this (see the local DNS resolver below)
- [x] Map: the mascot in the bottom-left corner looked cut off: kept, it is the intended "peeking over the edge"; the one next to Pause shows whether monitoring runs
- [x] Blocklists: list tiles keep a fixed width and leave half the row empty; "1 invalid lines" and "pf firewall enabled" fixed; tiles of a row share one height (the empty third column fills once there are more lists)
- [x] Checkup: the automatic updates sentence reads badly ("…automatically; off: installing App Store app updates"); list what is off as its own line

**New features**
- [x] Settings → General → Open Hector at login (`SMAppService.mainApp`, no Developer ID needed); shows when it was switched off in System Settings
- [x] Menu bar mode: keeps running with the window closed (no Dock icon then), a template Hector in the menu bar (watching while blocking, resting otherwise; camera and mic symbols when in use), a panel with the blocking state, devices in use and the last camera and mic events; Settings → General → Keep running in the menu bar (on by default)
  - [ ] Check on a real login that "Open at login" starts Hector in the menu bar without a window (the launch event's login-item flag, untested with `SMAppService`)
- [ ] Notifications: a camera or microphone turning on, a new keyboard tap that is active, a new persistence item, a new app making connections (each switchable)
- [ ] Persistence watch (in the spirit of BlockBlock): watch the launch agent and daemon folders and the background task list, and notify with the item's signature when something new appears; "new since last scan" badge
- [ ] Persistence actions (Reveal in Finder and Copy path exist): for user-scope items, disable or move to the Trash after confirmation (system items through the helper, with the authorization prompt)
- [ ] Checkup: more checks: screen lock and password after sleep, Find My, firewall stealth mode advice, AirDrop set to Everyone, Bluetooth sharing, macOS version behind the latest, Startup Security policy (reduced security, kernel extensions allowed), Lockdown Mode status (information only), and the date of the last check so a change shows
- [ ] Processes: CPU and memory columns, and "quit" or "show in Activity Monitor"
- [ ] Connections: traffic per app (bytes in and out) if it can be read without private frameworks; research `nettop`'s source
- [ ] First launch: a short onboarding (what each screen does, install the helper for blocking, optional VirusTotal key, open at login)

## 0.1: core and CLI

- [x] Socket collector per process (libproc), helpers grouped under their app
- [x] IPv4/IPv6 address and CIDR model, range → CIDR conversion
- [x] DB-IP Lite country database: download, load, lookup, country → networks
- [x] Blocklist model (domains, IPs, CIDRs, countries), JSON persistence
- [x] Compiler to pf anchor, pf tables and a managed `/etc/hosts` section, with safety rails
- [x] `hector connections | geo | rules` command-line tool
- [x] Unit tests (Swift Testing)
- [x] CI on GitHub Actions (build and test on macOS; shipped in 0.3)

## 0.2: the app

Based on the design mockup (main window and blocklist editor).

- [x] SwiftUI app shell: sidebar of apps and system processes, list of destinations per process
- [x] Live refresh (1 s): live and recent destinations kept for the session (30 min idle)
- [x] World map: arcs from the user's country to each destination; hovering a line highlights the app that owns it
- [x] Details panel: country, reverse DNS, activity, the apps that use the destination
- [x] App icons from the bundles, app icon drawn in code, `scripts/bundle-app.sh`
- [ ] Check the light appearance (only dark has been reviewed)
  - [x] Code review of the network screens: map land dots and dimmed lines made as visible as in dark mode, the status bar version no longer in tertiary gray
  - [ ] Look at every screen in light mode on a Mac
- [ ] Fix the AppKit "reentrant operation in its NSTableView delegate" warning logged at launch
  - [x] Likely cause fixed: list rows wrote the hovered destination from their hover handler, which can run while the table adds its rows; the write is now deferred and skipped when nothing changes
  - [ ] Confirm on a Mac that the warning is gone (see [NEXT_STEPS.md](NEXT_STEPS.md))
- [x] Network name (ASN) per destination: DB-IP IP to ASN Lite (CC BY 4.0), downloaded on request; list, details panel, map tooltip, search, `hector connections --asn`, `hector geo asn`

## 0.3: blocking from the app, downloadable release

- [x] `hectord` privileged helper: LaunchDaemon, Unix socket for administrators only, apply with roll back on pfctl failure, re-apply at boot, flush, uninstall
- [x] "Block this destination" and "Block all of <country>" from the details panel
- [x] Blocklists screen: per-country switches (all off by default), personal rules, pending changes with Apply / Discard
- [x] Blocked destinations in red on the map and in the list, "Blocked" filter
- [x] System processes visible through the helper
- [x] `hector helper status | apply | flush`, and a dry-run mode for the helper (`hectord serve --dry-run DIR`)
- [x] GitHub Actions: CI on every push, universal `Hector.app` published on every `v*` tag
- [x] Security review of the privileged code and fixes (see [SECURITY.md](../SECURITY.md)); tested for real: block, unauthorized requests refused, flush restores everything
- [x] Hector → Uninstall Hector…: helper, rules, logs, user data, Keychain item and the app; `scripts/check-uninstall.sh`
- [ ] Re-test the in-app uninstall end to end after the fix for the hang (install helper, uninstall, `scripts/check-uninstall.sh`); check System Settings → General → Login Items for a stale background item
- [x] Remove personal data before going public: rewrite the commits that carry a personal e-mail (use the GitHub noreply address), scan files and fixtures again, then force-push after explicit approval
- [x] First push of the workflows: confirm CI passes on GitHub's macOS runner (Xcode, not the Command Line Tools)
  - [x] First run failed on Swift 6.1.2 (Xcode 16.4): type-checker timeout in `MapGeometry.swift`, fixed
  - [x] CI also bundles the app; can be run by hand on a branch
- [x] Tag `v0.3.0` and check the published release (universal zip, SHA-256, release notes)
  - [x] Release workflow: dry run by hand (zip kept as an artifact), checks of the zip before publishing
- [x] Imported hosts lists (StevenBlack Unified, EasyPrivacy converted), with periodic updates (shipped in 0.4: downloaded by the helper from a fixed catalog, weekly conditional checks, Lists section and `hector lists`)
  - [ ] Check on a real Mac: resolution latency and mDNSResponder memory with ~110,000 domains in /etc/hosts
    - [x] Memory: about 20 MB resident for mDNSResponder with 113,627 list domains (2026-10-04, see [LOCAL_DNS.md](LOCAL_DNS.md))
    - [ ] Latency: only measured with 43,112 domains (6 ms blocked, 30 to 50 ms normal); measure again with both lists

## 0.4: Hector

Netbite grows into **Hector**, a small all-in-one security app for macOS. Netbite stays the name of its network module. Everything keeps working without a paid Apple Developer account.

- [x] Helper: connections served concurrently (rule changes serialized), and a `hello` handshake with version, protocol and capabilities so the app and the CLI name an outdated helper instead of failing to decode
- [x] Layout on macOS 26: the sidebar was drawn above the window and the top of the map cut off (split panes took a list's full height as their minimum; `fillsSplitPane()`)
- [x] **High priority: an interactive map.** Today every destination sits on its country's center with a small offset; arcs to nearby countries pile up on "You", and nothing can be filtered by country. Keep the drawn map (MapKit would fetch tiles from Apple and lose the style); everything already goes through `MapGeometry`, so:
  - [x] Filter by country: the "N countries" figure opens a list of countries with their counts; picking one (or clicking a country on the map) filters the map and the list, like the app filter, with a removable chip; the search also matches country names
  - [x] One node per country, with a count bubble, lines thicker for more destinations, and a hover card listing the apps; individual destinations fan out only when zoomed in
  - [x] Zoom and pan: pinch and drag on the trackpad, buttons to zoom, fit what is shown and show the world (zoom stops at 6×: the land is a 3.6° dot grid)
  - [ ] Zoom with ⌘ and the scroll wheel; keyboard shortcuts for the map buttons
    - [x] Keyboard shortcuts: ⌘= zoom in, ⌘- zoom out, ⌘9 fit, ⌘0 whole world, shown in the buttons' tooltips (to try on a Mac)
    - [ ] ⌘ and the scroll wheel (SwiftUI has no scroll-wheel event: needs an `NSEvent` monitor or an AppKit view under the map)
  - [ ] Later: city-level points would need a city database (DB-IP City Lite is about 130 MB); decide whether the gain is worth the size

- [x] Rename the app, the bundle, the helper, the CLI and the docs to Hector, with migration from Netbite 0.3 (helper, blocklist, data, VirusTotal key)
- [x] Rename the GitHub repository to `hector` (GitHub redirects the old URL)
- [x] Brand identity for Hector: the crested-helmet mark, the "Hector on the walls" app icon, the tone of voice, and a rewritten design brief (`docs/DESIGN.md`)
- [x] Core library and CLI for code signatures, SHA-256 and VirusTotal hash lookups (`hector sign`, `hector vt`)
- [x] Core library and CLI for the persistence scan (`hector persistence`)
- [x] App screens for Persistence and Processes, with signature and VirusTotal columns; settings to store the API key
- [x] Login items and background tasks through the helper (`sfltool dumpbtm` needs root)
- [ ] Check the `sfltool dumpbtm` parser against real output on macOS 15 and 26/27
  - [x] macOS 26.6: login items listed through the helper as root (2026-10-04, helper 0.4.2)
  - [ ] macOS 15 and 27
- [ ] Keychain: the API key item is tied to the binary that created it; decide how the app and the CLI share it without prompts
- [x] **VirusTotal**: personal API key stored in the Keychain; lookups by SHA-256 only, never uploading a file unless the user asks for that file; results cached; the free-tier limit (4 requests per minute, 500 per day) respected
- [x] **Persistence** (in the spirit of KnockKnock): launch agents and daemons, login items and background tasks, cron and periodic jobs, system extensions, configuration profiles, browser extensions. Each item with its code signature (Apple, Developer ID, ad hoc, unsigned), notarization, path, and VirusTotal score
- [x] **Processes** (in the spirit of TaskExplorer): process tree, signature, parent, arguments, open connections, VirusTotal score; flags for unsigned code and binaries running from temporary, Downloads or hidden folders, with the quarantine download URL
- [x] **Keyboard taps** (in the spirit of ReiKey): apps that intercept keystrokes, through the public event tap list (`hector taps`, Privacy → Keyboard taps)
- [x] **Camera and microphone**: log when they turn on, and which app uses them when it can be determined (`hector devices --watch`, Privacy → Camera & mic)
  - [ ] Check on a real Mac (see [NEXT_STEPS.md](NEXT_STEPS.md)): built-in and USB cameras, headsets, AirPods, Continuity Camera, virtual devices
  - [x] Which app uses a camera: Control Center's `sensor-indicators` log names the bundle ID behind the green indicator, readable by a normal user; trusted only when the sender is Control Center's own executable
  - [ ] Notifications when a device turns on, and a log kept across launches
- [x] **Security checkup**: SIP, Gatekeeper, FileVault, firewall, automatic updates, XProtect version, Remote Login and sharing services, MDM profiles, each with how to fix it (`hector checkup`, Checkup screen)
- [ ] Check the checkup's parsers and verdicts against real output on macOS 15 and 26/27 (see NEXT_STEPS.md)

## Next feature: Hector as a local Pi-hole

Hector already blocks ads and trackers for the whole Mac the way a Pi-hole does: by domain, with the same public lists (StevenBlack Unified is Pi-hole's default list), written to /etc/hosts. A local DNS resolver run by the helper would go further:

- [ ] **Wildcard blocking:** block `example.com` and every subdomain, which /etc/hosts cannot express (lists ship each subdomain separately today)
- [ ] **A query log per app:** which app asked for which name, blocked or allowed, with counts per day (Pi-hole's dashboard, for one Mac)
- [ ] **Allowlist** that wins over lists, one click from the log ("unblock this")
  - [x] In /etc/hosts mode (0.4.4): Blocklists → Allowlist; an entry unblocks its name and the names below it in lists and overrides personal domain rules, which say so
  - [ ] One click from the query log, once the resolver exists
- [ ] **More lists from the catalog**
  - [x] HaGeZi Light in hosts format (0.4.4); Normal and Pro exceed the per-list limit of /etc/hosts mode, all public and maintained: OISD (big and small), HaGeZi (Light, Normal, Pro, threat intelligence), AdGuard DNS filter, 1Hosts, Peter Lowe's list; each with its license, checked like today's lists
- [ ] **Design:** the helper listens on 127.0.0.1:53 and `[::1]:53` as an unprivileged child (port 53 bound by root, then handed over), and forwards to the user's DNS servers or to DNS over HTTPS; macOS is pointed at it with a resolver configuration that can be undone in one step. A crash must fall back to the normal DNS, never cut the Mac off
- [ ] Measure first: lookup latency and memory against /etc/hosts with 100,000+ domains (today: 43,112 list domains, 6 ms for a blocked name, 30 to 50 ms for normal names, no visible cost in mDNSResponder)
- [ ] Later: serve other devices on the network (a real Pi-hole replacement), off by default

Design, verified list URLs and a phased plan: [LOCAL_DNS.md](LOCAL_DNS.md). The pure core is written and tested (`HectorCore/DNS`: message parser, wildcard domain set, allowlist precedence, Adblock-style lists, attribution through mDNSResponder's log).

## 0.5: better names and numbers

- [ ] Real host names per connection: research reading DNS answers from mDNSResponder's unified log, or a local DNS forwarder
- [ ] Bytes per connection from the NetworkStatistics framework (the source `nettop` uses)
- [ ] Connection history in SQLite, kept 30 days by default

## Later

- [ ] **Hector in the app, a few small appearances** (detail, for personality): poses of the crested-helmet character drawn in code like the app icon (`HectorMark`, `AppIconArtwork`), no binary assets. Ideas: peering over the edge of the destination map; keeping watch beside Camera & mic (eyes open while monitoring, resting when paused); in the empty states ("All quiet", "Pick a destination"); a shield pose on the "Blocking on" footer. Small and calm, never in the way of the data; follow the tone in `docs/DESIGN.md`
- [ ] Real-time alerts when a new launch agent, daemon or login item appears (in the spirit of BlockBlock)
- [ ] Processes listening on the network, not just on this Mac
- [ ] Exportable report (JSON or HTML) and an event timeline
- [ ] Menu bar extra: live counters, pause blocking
- [ ] Notification when an app contacts a new country
- [ ] Optional Network Extension module for contributors with a developer account, to block per app and prompt on new connections

## Out of scope

- Per-app blocking and prompts in the default build: they require a paid Apple Developer account (see [ARCHITECTURE.md](ARCHITECTURE.md)).
- Telemetry. Cloud lookups happen only when the user turns them on (VirusTotal, with their own key).
