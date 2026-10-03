# Next steps

Hand-off notes for the next working session. The roadmap ([ROADMAP.md](ROADMAP.md)) has the full list; this page is the short, ordered version with the context needed to resume.

## Where things stand

- `main` holds 0.3 (helper, blocking, security review, uninstall) plus the merged 0.4 groundwork (code signatures, VirusTotal client, persistence scanner, all CLI and library, no UI yet).
- `swift build` has no warnings; `scripts/test.sh` runs 87 tests, all passing.
- Local `main` is **ahead of `origin/main` and not pushed** on purpose: history must be cleaned first (step 2).
- This repository's git identity is set to the GitHub noreply address (`git config --local user.email`), so new commits carry no personal e-mail.

## In order

1. **Re-test the in-app uninstall.** The first run removed everything but left the app waiting: the async `NSWorkspace.recycle` moved the bundle and never resumed. It now uses `FileManager.trashItem`, quits with `exit(0)`, and a detached shell deletes preferences and saved state once the app has exited. Steps: `scripts/bundle-app.sh`, open the app, Blocklists → Install helper…, then Netbite → Uninstall Netbite…, then `scripts/check-uninstall.sh` (expects "Nothing left"). Also look at System Settings → General → Login Items for a stale "netbited" background item.
2. **Personal data, before making the repository public.**
   - Commits `4f62b59`, `118e4bb`, `0230420` (already on GitHub) and the two agent commits `c9ef1c8`, `cd9cddf` have a personal e-mail as author and committer. Rewrite them with the noreply address (for example `git filter-repo --mailmap`, or `git rebase -r --root --exec 'git commit --amend --no-edit --reset-author'` with the local identity), then **force-push only after the owner approves**.
   - Scan every tracked file again: e-mail, real name, `/Users/` paths, data from the owner's machine in test fixtures or docs (README examples use addresses seen on that machine; replace them with documentation ranges such as 192.0.2.0/24 and 2001:db8::/32), keys and tokens.
   - Recommend enabling GitHub's "Keep my email addresses private" and "Block command line pushes that expose my email".
3. **First push and CI.** The workflows were never run on GitHub. After the push, check that CI passes on `macos-15` (Xcode there, so SwiftPM finds the Swift Testing plugin without `scripts/test.sh`).
4. **Release 0.3.0.** Tag `v0.3.0`; the Release workflow builds a universal app, zips it with its SHA-256 and uses `docs/RELEASE_NOTES.md`. Check the downloaded zip opens after the Gatekeeper step described there.
5. **0.4 Hexorcist.** Rename (app, bundle id, helper label, repository, docs), then build the Persistence and Processes screens on top of `PersistenceScanner`, `CodeSignature` and `VirusTotalClient`, and a settings screen for the API key. Login items need `sfltool dumpbtm` as root: add a helper request that returns its text, parsed by `PersistenceParsers.backgroundTaskItems` in the app.

## Things to know about this machine and toolchain

- Only the Command Line Tools are installed (27.0, Swift 6.4). With them:
  - SwiftPM does not pass the Swift Testing macro plugin path: use `scripts/test.sh`, not `swift test`.
  - In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode: do not use `@State`; keep view state in `WindowState` (an `@Observable` owned by the app).
- `sfltool dumpbtm` shows an administrator password prompt when run as a normal user: never run it outside the helper.
- The app checks itself without screen recording through debug-only environment variables (`NETBITE_SNAPSHOT`, `NETBITE_DEBUG_HOVER`, `NETBITE_DEBUG_SELECT`, `NETBITE_DEBUG_BLOCKLISTS`); see CONTRIBUTING.md.
- Agent worktrees live under `.claude/worktrees/` (ignored by git). Once their branches are merged, remove them with `git worktree remove` and delete the branches.
