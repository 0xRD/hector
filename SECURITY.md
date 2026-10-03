# Security

Netbite installs a helper that runs as root, so its security matters more than its features. This page describes what Netbite protects, what it trusts, the review done before 0.3, and the risks that remain.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting (Security → Report a vulnerability) on this repository, with steps to reproduce and the version (`netbite version`). Expect an answer within a week.

## Threat model

| Component | Runs as | Trusts |
|---|---|---|
| Netbite.app | the user | the helper's replies |
| `netbite` CLI | the user, or root with sudo | the helper's replies |
| `netbited` helper | **root** (LaunchDaemon) | nothing it receives; it revalidates every request |

The privilege boundary is the helper's Unix socket, `/var/run/io.github.0xrd.netbited.sock`.

Who may do what:

- **Read** (`status`, `snapshot`, `processes`, `backgroundTasks`): root and members of the admin group. The socket is `0660 root:admin` and the helper also checks the peer with `getpeereid`. A snapshot lists every process's connections, which an administrator can already see with `sudo lsof -i`; `processes` adds every process's arguments (`ps -axww` shows them to anyone; the environment is never read); `backgroundTasks` returns the output of `sfltool dumpbtm`, the login items and background tasks of every user. These requests take no input: the helper runs a fixed tool path with fixed arguments and only reads.
- **Change the firewall** (`apply`, `flush`): root, or a client holding the Authorization Services right `io.github.0xrd.netbite.modify-firewall`. The right requires an administrator's password in the system dialog and is remembered for five minutes by the process that asked for it. Belonging to the admin group is not enough: any process running as an administrator account, malware included, is in that group without knowing the password.

What the helper does with root, and nothing else:

- writes its own files under `/Library/Application Support/Netbite` (mode 0700, root only);
- loads the pf anchor `com.apple/250.Netbite`, takes and releases its own `pfctl -E` reference;
- rewrites the Netbite section of `/etc/hosts` and flushes the DNS cache;
- downloads the DB-IP country database over HTTPS when a country is blocked;
- lists processes and runs `/usr/bin/sfltool dumpbtm` for the read requests above;
- installs and uninstalls itself (`/Library/PrivilegedHelperTools`, `/Library/LaunchDaemons`, `/Library/Logs/Netbite`).

It runs fixed executables (`/sbin/pfctl`, `/usr/bin/dscacheutil`, `/usr/bin/killall`, `/bin/launchctl`, `/usr/bin/gunzip`) with argument arrays, never through a shell, and no argument comes from a client except values that were parsed and re-printed as addresses or networks.

## Review before 0.3

The privileged code was reviewed before the first release. Each issue below is fixed and covered by a regression test in `Tests/NetbiteCoreTests/SecurityHardeningTests.swift` where it can run without root.

| Severity | Issue | Fix |
|---|---|---|
| High | Any process running as an administrator account could change or remove the firewall rules through the socket, without the password. | `apply` and `flush` require the Authorization Services right above; forged or empty authorizations are rejected. |
| High | Text sent by a client (for example an invalid domain containing newlines) reached the root log unchanged, allowing forged log lines. | Every log line is sanitized: control characters escaped, length capped. The log file is created by the installer, root-owned, never through a symlink. |
| High | The GeoIP database downloaded as root accepted redirects to plain HTTP and was not checked. A forged file could have made a "country" cover the whole internet or the local network, bypassing the rule safety rails. | HTTPS only, redirects included; a database with fewer than 100,000 ranges or 200 countries is refused; country ranges go through the same rails as user rules (nothing wider than /8 or /16, nothing local or private). |
| Medium | A client sending one byte every few seconds could stall the helper, which serves one request at a time; requests could be 32 MB. | A whole request must arrive within 5 s and weigh at most 4 MB; at most 5,000 rules; notes at most 500 characters. |
| Medium | Country codes were not validated. | Exactly two letters A–Z, checked when decoding. |
| Medium | Files and directories were written as root without checking what was already there; the socket briefly existed with default permissions. | `SecureFiles`: `lstat` checks, root-owned directories, `O_NOFOLLOW` and `O_EXCL`, temp file then `rename`. The socket is created under `umask 0177`, then opened to the admin group. |
| Low | CI used actions referenced by tag, with default token permissions. | Actions pinned by commit, `contents: read` for CI, no persisted credentials. |

Already sound and kept: domains are restricted to letters, digits, `-` and `_` so they cannot inject lines into `/etc/hosts`; networks wider than /8 (IPv4) or /16 (IPv6) and local or private ranges are never blocked; the helper recompiles every blocklist instead of trusting compiled output; the app passes paths to `do shell script` quoted for the shell and for AppleScript.

## Residual risks

- **The helper is installed from the app bundle.** Without a Developer ID certificate, Netbite cannot prove that `Netbite.app/Contents/Helpers/netbited` is the one its authors built. A process already running as you could replace it just before you type your password in the install dialog, and it would then run as root. Install Netbite only from a release you verified (SHA-256 in the release notes) or that you built yourself, and keep it in /Applications.
- **Releases are ad-hoc signed and not notarized.** Gatekeeper cannot vouch for them; their integrity relies on GitHub and on the published SHA-256, which come from the same place. Building from source avoids this.
- **Reverse DNS names are claims, not facts.** A PTR record is set by whoever owns the address range and can say anything, `apple.com` included.
- **Blocking is system-wide and IP-based.** Content delivery networks share addresses across many sites: blocking one destination's address can block others. Domains in `/etc/hosts` are bypassed by apps that use their own DNS-over-HTTPS resolver.
- **Uninstall with Netbite → Uninstall Netbite…** (or `sudo netbited uninstall --purge`). Dragging the app to the Trash alone leaves the helper running with its rules.
