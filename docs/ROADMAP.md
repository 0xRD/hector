# Roadmap

## 0.1: core and CLI

- [x] Socket collector per process (libproc), helpers grouped under their app
- [x] IPv4/IPv6 address and CIDR model, range → CIDR conversion
- [x] DB-IP Lite country database: download, load, lookup, country → networks
- [x] Blocklist model (domains, IPs, CIDRs, countries), JSON persistence
- [x] Compiler to pf anchor, pf tables and a managed `/etc/hosts` section, with safety rails
- [x] `hector connections | geo | rules` command-line tool
- [x] Unit tests (Swift Testing)
- [ ] CI on GitHub Actions (build and test on macOS)

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

## 0.4: Hector

Netbite grows into **Hector**, a small all-in-one security app for macOS. Netbite stays the name of its network module. Everything keeps working without a paid Apple Developer account.

- [x] Rename the app, the bundle, the helper, the CLI and the docs to Hector, with migration from Netbite 0.3 (helper, blocklist, data, VirusTotal key)
- [ ] Rename the GitHub repository to `hector` (owner, in Settings; GitHub redirects the old URL)
- [x] Brand identity for Hector: the crested-helmet mark, the "Hector on the walls" app icon, the tone of voice, and a rewritten design brief (`docs/DESIGN.md`)
- [x] Core library and CLI for code signatures, SHA-256 and VirusTotal hash lookups (`hector sign`, `hector vt`)
- [x] Core library and CLI for the persistence scan (`hector persistence`)
- [x] App screens for Persistence and Processes, with signature and VirusTotal columns; settings to store the API key
- [x] Login items and background tasks through the helper (`sfltool dumpbtm` needs root)
- [ ] Check the `sfltool dumpbtm` parser against real output on macOS 15 and 26/27
- [ ] Keychain: the API key item is tied to the binary that created it; decide how the app and the CLI share it without prompts
- [x] **VirusTotal**: personal API key stored in the Keychain; lookups by SHA-256 only, never uploading a file unless the user asks for that file; results cached; the free-tier limit (4 requests per minute, 500 per day) respected
- [x] **Persistence** (in the spirit of KnockKnock): launch agents and daemons, login items and background tasks, cron and periodic jobs, system extensions, configuration profiles, browser extensions. Each item with its code signature (Apple, Developer ID, ad hoc, unsigned), notarization, path, and VirusTotal score
- [x] **Processes** (in the spirit of TaskExplorer): process tree, signature, parent, arguments, open connections, VirusTotal score; flags for unsigned code and binaries running from temporary, Downloads or hidden folders, with the quarantine download URL
- [x] **Keyboard taps** (in the spirit of ReiKey): apps that intercept keystrokes, through the public event tap list (`hector taps`, Privacy → Keyboard taps)
- [x] **Camera and microphone**: log when they turn on, and which app uses them when it can be determined (`hector devices --watch`, Privacy → Camera & mic)
  - [ ] Check on a real Mac (see [NEXT_STEPS.md](NEXT_STEPS.md)): built-in and USB cameras, headsets, AirPods, Continuity Camera, virtual devices
  - [ ] Which app uses a camera: research the unified log (`com.apple.cmio`, Control Center's privacy indicator) and keep it optional if it holds
  - [ ] Notifications when a device turns on, and a log kept across launches
- [x] **Security checkup**: SIP, Gatekeeper, FileVault, firewall, automatic updates, XProtect version, Remote Login and sharing services, MDM profiles, each with how to fix it (`hector checkup`, Checkup screen)
- [ ] Check the checkup's parsers and verdicts against real output on macOS 15 and 26/27 (see NEXT_STEPS.md)

## 0.5: better names and numbers

- [ ] Real host names per connection: research reading DNS answers from mDNSResponder's unified log, or a local DNS forwarder
- [ ] Bytes per connection from the NetworkStatistics framework (the source `nettop` uses)
- [ ] Connection history in SQLite, kept 30 days by default

## Later

- [ ] Real-time alerts when a new launch agent, daemon or login item appears (in the spirit of BlockBlock)
- [ ] Processes listening on the network, not just on this Mac
- [ ] Exportable report (JSON or HTML) and an event timeline
- [ ] Menu bar extra: live counters, pause blocking
- [ ] Notification when an app contacts a new country
- [ ] Optional Network Extension module for contributors with a developer account, to block per app and prompt on new connections

## Out of scope

- Per-app blocking and prompts in the default build: they require a paid Apple Developer account (see [ARCHITECTURE.md](ARCHITECTURE.md)).
- Telemetry. Cloud lookups happen only when the user turns them on (VirusTotal, with their own key).
