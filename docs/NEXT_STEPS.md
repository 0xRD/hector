# Next steps

Hand-off notes for the next working session. The roadmap ([ROADMAP.md](ROADMAP.md)) has the full list; this page is the short, ordered version with the context needed to resume.

## Where things stand

- `main` holds 0.3 (helper, blocking, security review, uninstall) plus the merged 0.4 groundwork (code signatures, VirusTotal client, persistence scanner, all CLI and library, no UI yet).
- `swift build` has no warnings; `scripts/test.sh` runs 87 tests, all passing.
- `main` is pushed to GitHub. Every commit on it has the GitHub noreply address as author and committer (checked with `git log --format="%ae %ce"`).
- This repository's git identity is set to the GitHub noreply address (`git config --local user.email`), so new commits carry no personal e-mail.

## In order

1. **Re-test the in-app uninstall.** The first run removed everything but left the app waiting: the async `NSWorkspace.recycle` moved the bundle and never resumed. It now uses `FileManager.trashItem`, quits with `exit(0)`, and a detached shell deletes preferences and saved state once the app has exited. Steps: `scripts/bundle-app.sh`, open the app, Blocklists → Install helper…, then Hector → Uninstall Hector…, then `scripts/check-uninstall.sh` (expects "Nothing left"). Also look at System Settings → General → Login Items for a stale "hectord" background item.
2. **Personal data, before making the repository public.**
   - Commits `4f62b59`, `118e4bb`, `0230420` (already on GitHub) and the two agent commits `c9ef1c8`, `cd9cddf` have a personal e-mail as author and committer. Rewrite them with the noreply address (for example `git filter-repo --mailmap`, or `git rebase -r --root --exec 'git commit --amend --no-edit --reset-author'` with the local identity), then **force-push only after the owner approves**.
   - Scan every tracked file again: e-mail, real name, `/Users/` paths, data from the owner's machine in test fixtures or docs (README examples use addresses seen on that machine; replace them with documentation ranges such as 192.0.2.0/24 and 2001:db8::/32), keys and tokens.
   - Recommend enabling GitHub's "Keep my email addresses private" and "Block command line pushes that expose my email".
3. **First push and CI.** The first run on GitHub (`main`, 05f9198) failed: `macos-15` uses Xcode 16.4, so **Swift 6.1.2**, much older than the local 6.4, and its type checker gave up on the arc sampling expression in `Sources/HectorApp/Map/MapGeometry.swift` ("unable to type-check this expression in reasonable time"). The expression is now split into typed steps. Everything else in the build compiled with 6.1; the tests had not been reached yet. CI now also bundles the app (`scripts/bundle-app.sh --zip`) and can be run by hand on any branch (Actions → CI → Run workflow). Keep in mind that CI checks the code with an older compiler than the one used locally: long arithmetic expressions and recent language features can pass locally and fail there.
4. **Release 0.3.0.** First a dry run: Actions → Release → Run workflow, on the branch to release. It runs the tests, builds the universal app, checks the zip (checksum, arm64 and x86_64 in every binary, signature, version) and keeps the zip, its `.sha256` and the filled release notes as a workflow artifact. Download it, then check on a Mac that it opens after the Gatekeeper step in `docs/RELEASE_NOTES.md`. Once `main` is green, tag `v0.3.0` on it and push the tag: the same steps run, then `gh release create` publishes the release. The `.sha256` file now names the zip alone, so `shasum -a 256 -c Netbite-0.3.0-macOS.zip.sha256` works next to the download.
5. **0.4 Hector.** Done on `claude/quirky-dirac-v51i1u` (green on CI, not yet tried on a Mac):
   - core: `ProcessCollector` (tree, arguments, connections; other users' processes through `sysctl` without root), `ProcessFlag`, `Quarantine` (download URL from the quarantine events database);
   - helper: two read-only requests, `processes` and `backgroundTasks` (`sfltool dumpbtm`); version bumped to 0.4.0, and Blocklists offers "Update helper…" when the installed helper is older;
   - app: Security section with Persistence and Processes screens (signature, VirusTotal, flags, quarantine), Settings (⌘,) for the VirusTotal key;
   - CLI: `hector processes`, and `hector persistence` lists login items through the helper.
   To check on a Mac: update the helper from Blocklists, then Persistence (login items present?), Processes (root daemons with arguments?), VirusTotal with a real key. The `sfltool dumpbtm` parser was written against sample output and must be checked against the real thing.
   Renamed to **Hector** (Netbite stays the network module): app `Hector.app` (`io.github.0xrd.hector`), CLI `hector`, helper `hectord` (`io.github.0xrd.hectord`). Installing the new helper stops and removes the Netbite helper and takes over its data folder, so the blocklist stays enforced (the pf anchor `250.Netbite` and the hosts section kept their names). At launch the app and the CLI move `~/Library/Application Support/Netbite` and the VirusTotal Keychain item to Hector's names. Uninstalling removes both generations; `scripts/check-uninstall.sh` checks both.
   To do by the owner: rename the GitHub repository to `hector` (Settings → Rename; GitHub redirects the old URL), then `git remote set-url origin https://github.com/0xRD/hector.git`.
6. **Security checkup** (`hector checkup`, Checkup in the sidebar). Written on Linux against outputs as best known for macOS 15; nothing has run on a Mac yet. To verify, as a normal user and again with `sudo`:
   - every tool answers without root and without a prompt: `csrutil status`, `spctl --status`, `fdesetup status`, `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate` and `--getstealthmode`, `launchctl print-disabled system`, `profiles status -type enrollment`; compare their text with the samples in `Tests/HectorCoreTests/CheckupTests.swift`;
   - toggle Remote Login, Screen Sharing, Remote Management, File Sharing and Remote Apple Events in System Settings → General → Sharing, and check that `launchctl print-disabled system` shows `com.openssh.sshd`, `com.apple.screensharing`, `com.apple.smbd`, `com.apple.AEServer` as enabled, and that `/Library/Application Support/Apple/Remote Desktop/RemoteManagement.launchd` reads `enabled` for Remote Management (both are assumptions);
   - the automatic update keys in `/Library/Preferences/com.apple.SoftwareUpdate.plist` (`AutomaticCheckEnabled`, `AutomaticDownload`, `AutomaticallyInstallMacOSUpdates`, `CriticalUpdateInstall`, `ConfigDataInstall`) and `AutoUpdate` in `com.apple.commerce.plist` follow the switches; a missing `AutomaticallyInstallMacOSUpdates` is treated as off;
   - the XProtect version matches `xprotect version` (macOS 15 may keep the current bundle in `/var/protected/xprotect`, readable by root only);
   - automatic login (`autoLoginUser`, `/etc/kcpassword`) and the guest account (`GuestEnabled`) in `/Library/Preferences/com.apple.loginwindow.plist`;
   - every "Open Settings" button lands on the right pane on macOS 15 and 26.

6. **Netbite 0.2 leftovers** (branch `netbite-asn`, written without a Mac or a Swift toolchain: build and test first, `swift build` and `scripts/test.sh`).
   - **Network names (ASN).** Source: DB-IP "IP to ASN Lite", `https://download.db-ip.com/free/dbip-asn-lite-YYYY-MM.csv.gz`, columns `start_ip,end_ip,as_number,as_organization`, CC BY 4.0. The URL pattern and columns could not be fetched from this sandbox: run `hector geo update --asn` once and check that it installs, then `head` the CSV in `~/Library/Application Support/Hector/dbip-asn-lite.csv` (organization names with commas must be quoted). Note the printed range and network counts (the updater refuses fewer than 50,000 ranges or 5,000 networks), the load time of `hector geo asn 8.8.8.8`, and the app's memory before and after the database loads (Activity Monitor). In the app: details panel → Network → Download Network Names, then the list's second line, the map tooltip, and a search for "google" or "as15169".
   - **NSTableView warning.** Launch from a terminal (`swift run HectorApp`, or `.build/Hector.app/Contents/MacOS/HectorApp`) with the pointer over the window and look for "reentrant operation in its NSTableView delegate". If it is still there, bisect: remove the list rows' `.onHover` for a run, then the map; the next suspects are the sidebar's `onChange` that clears the selected destination, and the list's selection binding when the selected row disappears from the list.
   - **Light appearance.** System Settings → Appearance → Light, then every screen: the map (land dots and dimmed lines were made darker in light mode), pills on selected rows, banners, the inspector.
   - The country download now shares its code with the ASN one (`DBIPDownload`) and gained size limits; the helper uses it when a country is blocked, so check that blocking a country with no database installed still downloads it.

## Things to know about this machine and toolchain

- Only the Command Line Tools are installed (27.0, Swift 6.4). With them:
  - SwiftPM does not pass the Swift Testing macro plugin path: use `scripts/test.sh`, not `swift test`.
  - In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode: do not use `@State`; keep view state in `WindowState` (an `@Observable` owned by the app).
- `sfltool dumpbtm` shows an administrator password prompt when run as a normal user: never run it outside the helper.
- The app checks itself without screen recording through debug-only environment variables (`HECTOR_SNAPSHOT`, `HECTOR_DEBUG_HOVER`, `HECTOR_DEBUG_SELECT`, `HECTOR_DEBUG_BLOCKLISTS`); see CONTRIBUTING.md.
- Agent worktrees live under `.claude/worktrees/` (ignored by git). Once their branches are merged, remove them with `git worktree remove` and delete the branches.
