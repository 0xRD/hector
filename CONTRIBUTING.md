# Contributing to Hector

Thanks for helping. Hector runs with root privileges once the helper is installed, so correctness and a small attack surface matter more than features.

## Ground rules

- Everything in the project is in English: code, comments, docs, UI text, commit messages.
- `HectorCore` stays free of UI code and privileged code. Code that needs root belongs in the helper and should be as small as possible.
- No new third-party dependencies without discussing them in an issue first.
- No telemetry, analytics or network calls other than the user-triggered DB-IP database downloads (countries, network names).

## Workflow

1. Open an issue describing the bug or the feature, unless it is trivial.
2. Create a branch, make the change, and add tests in `Tests/HectorCoreTests` for anything in the core library.
3. Make sure `swift build` and `scripts/test.sh` (which runs `swift test`) pass. If your toolchain is broken, use `scripts/build.sh` and say so in the pull request.
4. Open a pull request that explains what changed and how you tested it.

## Style

- Swift 6 language mode, strict concurrency.
- Follow the existing code: small types, `///` doc comments on public API, comments that explain *why* rather than what.
- Prefer clear names over abbreviations.

## Checking the app without clicking around

Debug builds of the app read three environment variables, so UI changes can be checked from a script:

- `HECTOR_SNAPSHOT=/tmp/shot.png` writes the window to a PNG after `HECTOR_SNAPSHOT_DELAY` seconds (6 by default), then quits;
- `HECTOR_DEBUG_HOVER=N` simulates the pointer over the N-th line of the map;
- `HECTOR_DEBUG_SELECT=N` selects the N-th line of the map.

```bash
HECTOR_SNAPSHOT=/tmp/shot.png HECTOR_DEBUG_HOVER=0 swift run HectorApp
```

## Testing changes that touch the firewall

Never test blocking on your daily machine first. Use a macOS virtual machine (UTM or Tart), and keep this command at hand; it removes every Netbite pf rule:

```bash
sudo pfctl -a com.apple/250.Netbite -F all
```

## License

By contributing, you agree that your contributions are licensed under the GNU General Public License v3.0.
