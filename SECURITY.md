# Security

Hector installs a helper that runs as root, so its security matters more than its features. This page describes what Hector protects, what it trusts, the review done before 0.3, and the risks that remain.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting (Security → Report a vulnerability) on this repository, with steps to reproduce and the version (`hector version`). Expect an answer within a week.

## Threat model

| Component | Runs as | Trusts |
|---|---|---|
| Hector.app | the user | the helper's replies |
| `hector` CLI | the user, or root with sudo | the helper's replies |
| `hectord` helper | **root** (LaunchDaemon) | nothing it receives; it revalidates every request |

The privilege boundary is the helper's Unix socket, `/var/run/io.github.0xrd.hectord.sock`.

Who may do what:

- **Read** (`hello`, `status`, `snapshot`, `processes`, `backgroundTasks`, `rootPersistence`): root and members of the admin group. The socket is `0660 root:admin` and the helper also checks the peer with `getpeereid`. A snapshot lists every process's connections, which an administrator can already see with `sudo lsof -i`; `processes` adds command-line arguments, but only for the caller's own processes and for root's: macOS hides other users' arguments from everyone but root, and they can hold passwords or tokens, so the helper leaves them out (`ProcessSnapshot.visible(to:)`; the environment is never read); it also gives each process's CPU share, memory footprint and listening ports, which an administrator can already read with `sudo ps` and `sudo lsof -i -P`; `backgroundTasks` returns the output of `sfltool dumpbtm`, the login items and background tasks of every user. `rootPersistence` returns what only root can read about persistence, made for the caller (see [Root-only persistence](#root-only-persistence)). These requests take no input: the helper runs a fixed tool path with fixed arguments, or opens fixed paths, and only reads. `hello` returns the helper's version, protocol number and the requests it supports, so the app can tell an outdated helper from a failure.
- **Concurrency.** The helper serves up to 8 connections at once (more wait in the listen backlog), each still bounded by the 5 s / 4 MB request limits. Everything that reads or changes the rules (`status`, `apply`, `flush`, `refreshHostsLists`, and the scheduled list refresh) runs one at a time on a single serial queue, in arrival order; snapshots, processes, login items, `rootPersistence` and `hello` run alongside (one persistence scan at a time, its answer reused for 5 s). The client must also have read the whole answer within 15 s. A slow apply therefore never delays the app's once-per-second snapshot, and two changes can never interleave.
- **Change the firewall** (`apply`, `flush`, `refreshHostsLists`): root, or a client holding the Authorization Services right `io.github.0xrd.hector.modify-firewall`. The right requires an administrator's password in the system dialog and is remembered for five minutes by the process that asked for it. Belonging to the admin group is not enough: any process running as an administrator account, malware included, is in that group without knowing the password.

What the helper does with root, and nothing else:

- writes its own files under `/Library/Application Support/Hector` (mode 0700, root only);
- loads the pf anchor `com.apple/250.Netbite`, takes and releases its own `pfctl -E` reference;
- rewrites the Netbite section of `/etc/hosts` and flushes the DNS cache;
- has the DB-IP country database downloaded when a country is blocked, and the hosts lists the user subscribed to, from the fixed HTTPS addresses of its built-in catalog, when they are applied and then at most weekly; the downloads themselves run in a child that is not root (see [Unprivileged downloads](#unprivileged-downloads));
- lists processes, runs `/usr/bin/sfltool dumpbtm`, and reads the persistence files only root can read (crontabs, sudoers, every user's authorized SSH keys and shell startup files, root's login hooks) for the read requests above;
- installs and uninstalls itself (`/Library/PrivilegedHelperTools`, `/Library/LaunchDaemons`, `/Library/Logs/Hector`).

It runs fixed executables (`/sbin/pfctl`, `/usr/bin/dscacheutil`, `/usr/bin/killall`, `/bin/launchctl`, `/usr/bin/sfltool`, `/usr/bin/gunzip`) by absolute path, with argument arrays and a fixed environment, never through a shell, and no argument comes from a client except values that were parsed and re-printed as addresses or networks. The helper and the CLI are signed with the hardened runtime (no injected libraries, no `DYLD_*` variables).

## Unprivileged downloads

Downloading means TLS, HTTP, redirects, gzip and parsing files written by third parties: a large attack surface that needs no privilege. The helper therefore starts itself again (`hectord fetch-list ID` or `hectord fetch-countries`, by its own root-owned path) with a fixed environment, no standard input and a fresh temporary folder under `/private/var/tmp` (created by root with `mkdtemp`, mode 0700, given to `nobody`). Before anything else, the child drops every supplementary group, then its group and user IDs to `nobody`, and stops unless `setuid(0)` then fails. It downloads, decompresses and parses as `nobody` and writes its result to standard output.

The root side reads at most 48 MB (lists) or 256 MB (country CSV) and kills the child after a time limit. It trusts nothing in the output: list domains are parsed again with `HostsListParser` (every name through `DomainPattern`) and checked for plausibility, validators (`ETag`, `Last-Modified`) are re-validated, and the country CSV is parsed again before use. A compromise of the download path therefore lands in an unprivileged process whose only output is re-checked data.

## Hosts lists

Hosts lists (StevenBlack Unified, EasyPrivacy, HaGeZi Light) are downloaded **for the helper** (by its unprivileged child, see above), not by the app, and bounded on every side:

- **No URL crosses the socket.** A blocklist carries list identifiers only (`"hostsLists": ["stevenblack-unified"]`). The helper accepts identifiers of its own built-in catalog (`HostsListCatalog`) and refuses any other; the URLs are constants in the code. There are no custom lists: a custom URL would let any process that obtained the authorization make root fetch an arbitrary address (local services included) and feed /etc/hosts with an arbitrary file.
- **Why the helper downloads.** If the app downloaded and sent the domains, a request would carry 100,000 names (beyond the 5,000-rule and 4 MB limits), and a non-root process could inject a crafted set. With identifiers only, requests stay small and the helper alone decides what it trusts. The requests go through `URLSession` with an ephemeral configuration (no cookies, no cache), in the unprivileged child.
- **Transport.** HTTPS only; a redirect is followed only to HTTPS on the same host as the catalog URL. Every request has a 20 s idle timeout and a 30 s total timeout.
- **Size.** A response larger than 16 MB (after HTTP decompression) is refused while it arrives, before it is all in memory. A list with more than 300,000 valid domains is refused; all lists together never put more than 400,000 domains in /etc/hosts.
- **Content.** The body must be valid UTF-8. A strict parser (`HostsListParser`) reads `0.0.0.0 name`, `127.0.0.1 name`, `:: name`, `::1 name` and plain `name` lines; everything else is counted as invalid. Every name goes through the same validation as personal rules (`DomainPattern`: letters, digits, `-` and `_`, labels of 1 to 63 characters), so a list cannot inject lines into /etc/hosts. International names are converted to punycode, or dropped.
- **Never a redirection.** A line mapping a name to any other address (`203.0.113.7 bank.example`) is skipped: Hector only ever points a name at `0.0.0.0` and `::`. Lists cannot redirect traffic, only block names.
- **Never the system's names.** `localhost`, `broadcasthost`, the `ip6-*` names, single-label names and names under `.local`, `.localhost`, `.localdomain`, `.arpa` and `.internal` are skipped, as are the hosts Hector downloads from (`raw.githubusercontent.com`, `github.com`, `download.db-ip.com`), so a list cannot stop its own updates or the country database.
- **Plausibility.** A download with fewer valid domains than expected for that list (an error page, an emptied file) is refused. A failed or refused download keeps the last good copy in force; the error is shown in the app.
- **Storage.** Validated copies are written with `SecureFiles` into `/Library/Application Support/Hector/lists` (0700, root). They are parsed again with the same rules when loaded, and the compiler checks every name once more before writing /etc/hosts.
- **Requests.** `refreshHostsLists` needs the same authorization as `apply`. Scheduled checks happen at most weekly per list (6 hours after a failure), with conditional requests (`If-None-Match`, `If-Modified-Since`); they download in the background so the helper keeps answering, and only the server loop changes files.

Trust: subscribing to a list means trusting its maintainers to choose which names fail to resolve on this Mac. They cannot redirect traffic or reach beyond /etc/hosts, but a list could block a site you need; personal rules cannot unblock a list entry (unsubscribe from the list instead).

## Root-only persistence

Since 0.5.1 the helper answers `rootPersistence`: the places malware uses to come back that only root can read. It is the helper's first request that opens files other users control, so it is built around that.

What it reads, and what leaves the helper:

| Place | Returned |
|---|---|
| `/usr/lib/cron/tabs/*` | The jobs of the caller's own table and of root's. Another user's jobs are listed with their schedule and the command hidden: a cron line can hold a password, and macOS shows it to nobody else. |
| `/etc/sudoers`, `/etc/sudoers.d/*` | Facts only: number of rules, owner, date, and red flags (`NOPASSWD`, `!authenticate`, `env_keep` of `DYLD_*`, includes from elsewhere). Never a rule: which commands need no password is not for every administrator process to learn. |
| `~/.ssh/authorized_keys` (and `authorized_keys2`) of every account | Per key: type, SHA-256 fingerprint, option names. The comment and the text of `command="…"` only for the caller's and root's keys. |
| Shell startup files of every account (`.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`, `.zlogout`, `.bash_profile`, `.bash_login`, `.bashrc`, `.bash_logout`, `.profile`, fish's `config.fish`, `.ssh/rc`) | Facts only, the caller's own included: size, date, owner, and the names of the red flags found (downloads and runs code, decodes base64, opens a network connection, sets a `DYLD_*` variable, redefines `sudo`, runs an inline script, starts a background job). Never a line: these files hold tokens. |
| `LoginHook` and `LogoutHook` in root's `com.apple.loginwindow` preferences | The command. |

What every user can read is not the helper's job and is read by the app as the user: `/etc/crontab`, the `at` spool (names only, a job is never opened), `/etc/periodic`, `/Library/Security/SecurityAgentPlugins`, `/etc/pam.d` and `/usr/local/lib/pam`, the shell files of `/etc`, login hooks in `/Library/Preferences`, and `DYLD_*` variables in launchd plists.

How it stays safe:

- **No input.** The request is `{"rootPersistence":{}}`. No path and no user name crosses the socket: paths are constants in the code, accounts come from the user database (`getpwent`), and the reader is the peer's user ID from `getpeereid`. Unknown fields in the request are ignored.
- **No program is started** and nothing is written. The sandbox profile is unchanged.
- **A user cannot aim the scan at a file that is not theirs.** Every file is opened through `GuardedDirectory`: the path is walked one component at a time from `/` with `O_NOFOLLOW` at every step (not only the last one), only regular files are read, opening never blocks (a named pipe at `~/.zshrc` would otherwise hang root), and what was checked is what is read (`openat` and `fstat` on the open file, no path to swap in between). A file in a home folder that its account does not own is not read at all (a hard link keeps its owner). A home folder reached through a symbolic link is skipped and reported.
- **Bounded.** At most 1 MB per crontab, sudoers or key file, 512 KB per shell file, 256 accounts, 200 keys per file, 500 jobs per crontab, 5,000 items per source; text shown from files has its control characters removed and its length cut. One scan runs at a time and its answer is reused for 5 s, so repeated requests cost one scan every 5 s whatever their number (about 17 ms on a Mac with two users, measured on a release build); a client waits 20 s at most, and no scan starts behind one that hangs.
- **No authorization, like the other read requests,** and that is why the answer is cut down as above rather than complete: any process of an administrator account can ask. What it learns that it could not before: root's cron jobs, login hooks and key comments, that another user has cron jobs or keys (not what they are), and which red flags a file raises.

Limits: the red flags are a short list of patterns, not an analysis: a clean result does not mean a clean file, and `nohup` in your own `.zshrc` is flagged too. macOS may refuse the crontab folder even to root (it is protected like Full Disk Access data); the helper then says so and the app falls back to `crontab -l` for your own table. `ZDOTDIR`, `AuthorizedKeysFile` and `AuthorizedKeysCommand` in `sshd_config`, and what the authorization database references are not followed.

## Sandbox

Since 0.4.2, `hectord serve` puts itself in a sandbox (`sandbox_init`, the Sandbox Profile Language, no entitlement needed) before it reads a file or a request. The profile cannot be lifted by the process and is inherited by every child, so it also covers pfctl, sfltool and the download children. `hectord sandbox-profile` prints it. Checked as root on macOS 26.6 (0.4.2): applying a blocklist with hosts lists and reading login items work inside it, with no denial in the system log. Under it, root can only:

- write to the helper's data folder, `/etc/hosts` (and its temporary sibling), its socket, its log, `/dev/pf`, `/dev/null` and the download children's private folders;
- start `/sbin/pfctl`, `/usr/bin/dscacheutil`, `/usr/bin/killall`, `/usr/bin/sfltool`, `/usr/bin/gunzip` (only the unprivileged download child runs it, on the country database) and its own binary; no shell, no other program;
- not set the setuid or setgid bit on anything.

A flaw in the helper therefore cannot be used to install a LaunchDaemon, replace a binary, edit sudoers or start a shell as root. Reading stays allowed (listing processes and sockets is the helper's job), and so do network connections (the download children). If the system refuses the profile, the helper keeps enforcing the blocklist without it rather than leaving the Mac unprotected, logs a warning, and `hector helper status` says "not sandboxed".

## Review before 0.3

The privileged code was reviewed before the first release. Each issue below is fixed and covered by a regression test in `Tests/HectorCoreTests/SecurityHardeningTests.swift` where it can run without root.

| Severity | Issue | Fix |
|---|---|---|
| High | Any process running as an administrator account could change or remove the firewall rules through the socket, without the password. | `apply` and `flush` require the Authorization Services right above; forged or empty authorizations are rejected. |
| High | Text sent by a client (for example an invalid domain containing newlines) reached the root log unchanged, allowing forged log lines. | Every log line is sanitized: control characters escaped, length capped. The log file is created by the installer, root-owned, never through a symlink. |
| High | The GeoIP database downloaded as root accepted redirects to plain HTTP and was not checked. A forged file could have made a "country" cover the whole internet or the local network, bypassing the rule safety rails. | HTTPS only, redirects included; a database with fewer than 100,000 ranges or 200 countries is refused; the compressed file is capped at 150 MB and decompression stops at 600 MB; country ranges go through the same rails as user rules (nothing wider than /8 or /16, nothing local or private). |
| Medium | A client sending one byte every few seconds could stall the helper, which served one request at a time; requests could be 32 MB. | A whole request must arrive within 5 s and weigh at most 4 MB; at most 5,000 rules; notes at most 500 characters. |
| Medium | Country codes were not validated. | Exactly two letters A–Z, checked when decoding. |
| Medium | Files and directories were written as root without checking what was already there; the socket briefly existed with default permissions. | `SecureFiles`: `lstat` checks, root-owned directories, `O_NOFOLLOW` and `O_EXCL`, temp file then `rename`. The socket is created under `umask 0177`, then opened to the admin group. |
| Low | CI used actions referenced by tag, with default token permissions. | Actions pinned by commit, `contents: read` for CI, no persisted credentials. |

Already sound and kept: domains are restricted to letters, digits, `-` and `_` so they cannot inject lines into `/etc/hosts`; networks wider than /8 (IPv4) or /16 (IPv6) and local or private ranges are never blocked; the helper recompiles every blocklist instead of trusting compiled output; the app passes paths to `do shell script` quoted for the shell and for AppleScript.

## Review before 0.5.1

The helper was reviewed again before it was given the root-only persistence scan. Fixed:

| Severity | Issue | Fix |
|---|---|---|
| Medium | `hectord install` copied the helper with `FileManager.copyItem`, which also copies the source's access control list and extended attributes. The source is in the app bundle, which the user owns: an ACL entry put on it by any process of that user stayed on the root-owned copy in `/Library/PrivilegedHelperTools` and let that process rewrite the binary launchd runs as root, whatever its owner and mode. (It needed the same foothold as replacing the helper before the install, see Residual risks, but survived a later verification of the app.) | Only the bytes are copied, into a file root creates with `O_EXCL` and renames into place: no ACL, no attribute. |
| Low | The answer was written with a 2 s limit per write but none overall: eight clients reading a few bytes at a time could hold every client slot. | The whole answer must be read within 15 s. |
| Low | The peer's groups were looked up with `getpwuid`, whose answer lives in shared storage, from several threads. The socket's own mode made this unreachable for non-administrators. | `getpwuid_r`. |
| Low | The cleanup of old download folders removed any folder named `hectord-fetch.*` in `/private/var/tmp`, which any user can create. The sandbox already kept such a removal inside those folders. | Only folders owned by `nobody` (what the download child creates) are removed. |

Looked at and kept: the socket (created under `umask 0177`, then `0660 root:admin`, peer checked again), the authorization check, the request limits, the unprivileged downloads, and `SecureFiles`. Not changed, and listed under Residual risks: the helper's log has no size limit, and the sandbox is not a full boundary.

## Privacy monitors

The keyboard tap list and the camera and microphone monitor run in the app and the CLI as the user, never in the helper. They only read:

- the event tap list of the window server (`CGGetEventTapList`), which any process may read; Hector installs no tap and never sees a keystroke;
- the "running somewhere" flag of each camera (CoreMediaIO) and audio input (Core Audio), and the PIDs of the processes recording audio (Core Audio process objects).

No device is opened, so macOS asks for no camera or microphone permission and its green or orange indicator never turns on because of Hector. The camera and microphone log stays in memory and is never written to disk or sent anywhere.

What these screens cannot promise: a tap list does not cover every way to read keystrokes, the app using a camera is not identified, and a process that records for less than the 2-second read interval may be logged with no app. See [ARCHITECTURE.md](docs/ARCHITECTURE.md#privacy-monitors) for the details.

## Residual risks

- **The helper is installed from the app bundle.** Without a Developer ID certificate, Hector cannot prove that `Hector.app/Contents/Helpers/hectord` is the one its authors built. A process already running as you could replace it just before you type your password in the install dialog, and it would then run as root. Install Hector only from a release you verified (SHA-256 in the release notes) or that you built yourself, and keep it in /Applications.
- **The helper cannot check who its client is beyond the account.** It checks that the peer is root or an administrator (`getpeereid`), and changes need the authorization above. Checking the client's code signature would need a signing identity to pin; with ad hoc signing there is none, so any administrator process can read what the read requests return (connections, processes without other users' arguments, login items).
- **The sandbox limits writes and programs, not reads.** A compromised helper could still read any file and talk to the network. A deny-by-default profile would need every service pfctl, sfltool and Foundation talk to, which changes between macOS versions; see [Sandbox](#sandbox).
- **The sandbox is a mitigation, not a boundary.** It denies writes and other programs, but the helper may still talk to system services as root (Authorization Services among them). A flaw that gives code execution in the helper should be treated as root.
- **The helper's log is not rotated.** Each failed request adds a line (at most 2,000 characters) to `/Library/Logs/Hector/hectord.log`; a process of an administrator account could make it grow. It could fill the disk from its own home folder just as well.
- **Releases are ad-hoc signed and not notarized.** Gatekeeper cannot vouch for them; their integrity relies on GitHub and on the published SHA-256, which come from the same place. Building from source avoids this.
- **Reverse DNS names are claims, not facts.** A PTR record is set by whoever owns the address range and can say anything, `apple.com` included.
- **The security checkup is a snapshot, not a guarantee.** It runs as the user and only reads: Apple's tools (`csrutil`, `spctl`, `fdesetup`, `socketfilterfw`, `launchctl print-disabled`, `profiles status`) by absolute path with fixed arguments, never through a shell, and world-readable preference files. It never asks for a password and never changes a setting; what only root can read is reported as unknown. Its "Open Settings" buttons open `x-apple.systempreferences:` links only. Malware with root could lie to these tools, and a passing check says nothing about what is already installed.
- **Hosts lists come from third parties over the network.** They are downloaded and parsed as `nobody`, then checked again by root. See [Hosts lists](#hosts-lists) for the bounds. A compromise of the list's GitHub repository could block arbitrary names (not redirect them) until the next update or until you unsubscribe.
- **Size limits.** At most 150,000 networks in the pf tables (pf allows about 200,000 for the whole system; the United States alone has more than 250,000, so it cannot be blocked by country) and 400,000 domains from hosts lists. Lookups stay fast at these sizes: pf tables are radix trees checked on the first packet of a connection only, and mDNSResponder indexes /etc/hosts when it changes rather than reading it per lookup; the cost is memory and the time to reload.
- **Blocking is system-wide and IP-based.** Content delivery networks share addresses across many sites: blocking one destination's address can block others. Domains in `/etc/hosts` are bypassed by apps that use their own DNS-over-HTTPS resolver.
- **Uninstall with Hector → Uninstall Hector…** (or `sudo hectord uninstall --purge`). Dragging the app to the Trash alone leaves the helper running with its rules.
