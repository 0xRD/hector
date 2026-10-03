# Roadmap

## 0.1: core and CLI

- [x] Socket collector per process (libproc), helpers grouped under their app
- [x] IPv4/IPv6 address and CIDR model, range → CIDR conversion
- [x] DB-IP Lite country database: download, load, lookup, country → networks
- [x] Blocklist model (domains, IPs, CIDRs, countries), JSON persistence
- [x] Compiler to pf anchor, pf tables and a managed `/etc/hosts` section, with safety rails
- [x] `netbite connections | geo | rules` command-line tool
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
- [ ] Fix the AppKit "reentrant operation in its NSTableView delegate" warning logged at launch
- [ ] Network name (ASN) per destination

## 0.3: blocking from the app

- [ ] `netbited` privileged helper: install, apply, verify, roll back, uninstall
- [ ] "Block this destination" and "Block all of <country>" from the details panel
- [ ] Blocklist editor: rules, imported lists, a per-country toggle (all off by default), pending changes with Apply / Discard
- [ ] Imported hosts lists (StevenBlack Unified, EasyPrivacy converted), with periodic updates

## 0.4: better names and numbers

- [ ] Real host names per connection: research reading DNS answers from mDNSResponder's unified log, or a local DNS forwarder
- [ ] Bytes per connection from the NetworkStatistics framework (the source `nettop` uses)
- [ ] Connection history in SQLite, kept 30 days by default

## Later

- [ ] Menu bar extra: live counters, pause blocking
- [ ] Notification when an app contacts a new country
- [ ] Optional Network Extension module for contributors with a developer account, to block per app and prompt on new connections

## Out of scope

- Per-app blocking and prompts in the default build: they require a paid Apple Developer account (see [ARCHITECTURE.md](ARCHITECTURE.md)).
- Any telemetry or cloud service.
