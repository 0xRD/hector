import Darwin
import Foundation
import HectorCore

// hectord: the only part of Hector that runs as root. It enforces a blocklist with pf and
// /etc/hosts and answers the app over a Unix socket that only administrators can open.
// See SECURITY.md for the threat model.

let usage = """
hectord \(HectorVersion.current): the Hector privileged helper.

USAGE
  hectord serve                  Run the helper (started by launchd)
  hectord serve --dry-run DIR [--socket PATH]
                                  Run without root: paths live under DIR, commands are only logged,
                                  and requests are not checked for an authorization
  hectord install                Install as a LaunchDaemon (run as root)
  hectord uninstall [--purge]    Remove every rule, then the LaunchDaemon (run as root);
                                  --purge also deletes the helper's logs
  hectord version
"""

let adminGroupID: gid_t = 80

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Server

func serve(dryRunRoot: URL?, socketPath: String) async throws -> Never {
    signal(SIGPIPE, SIG_IGN)
    let enforcer = try Enforcer(root: dryRunRoot)
    if dryRunRoot == nil {
        do { try HelperAuthorization.defineRight() } catch { log("Could not define the authorization right: \(error)") }
    }
    enforcer.restoreAtLaunch()

    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { throw HelperError("socket") }
    var address = try LineSocket.address(socketPath)
    // Create the socket node with no permissions for anyone but the owner, then open it to the
    // admin group: there is no window where other users could connect.
    let previousMask = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(previousMask)
    guard bound == 0 else { throw HelperError("bind \(socketPath): \(String(cString: strerror(errno)))") }
    if geteuid() == 0 {
        guard chown(socketPath, 0, adminGroupID) == 0, chmod(socketPath, 0o660) == 0 else {
            throw HelperError("Cannot set the socket permissions.")
        }
    }
    guard listen(server, 8) == 0 else { throw HelperError("listen") }
    log("hectord \(HectorVersion.current) listening on \(socketPath)\(dryRunRoot.map { " (dry run in \($0.path))" } ?? "")")

    // Connections are served side by side (at most `HelperLimits.maximumConcurrentClients`), so
    // the app's once-per-second snapshot never waits behind a long apply. Everything that reads or
    // changes the rules goes through `gate`, one at a time. Between connections, and at least
    // every few minutes when nobody talks to the helper, subscribed hosts lists that are due are
    // downloaded again.
    let gate = EnforcerGate(enforcer)
    let clients = DispatchQueue(label: "io.github.0xrd.hectord.clients", attributes: .concurrent)
    let slots = DispatchSemaphore(value: HelperLimits.maximumConcurrentClients)
    let dryRun = dryRunRoot != nil
    let waitMilliseconds = Int32(HostsListCatalog.checkInterval * 1_000)
    while true {
        var descriptor = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        // While a scheduled download runs in the background, wake up often to collect it.
        let refreshing = gate.sync { $0.isRefreshingInBackground }
        if poll(&descriptor, 1, refreshing ? 1_000 : waitMilliseconds) > 0 {
            slots.wait()
            let client = accept(server, nil, nil)
            if client >= 0 {
                clients.async {
                    handle(client: client, gate: gate, dryRun: dryRun)
                    close(client)
                    slots.signal()
                }
            } else {
                slots.signal()
            }
        }
        gate.async { $0.refreshHostsListsIfDue() }
    }
}

/// The only way to the `Enforcer`, which is not thread-safe: whatever reads or changes the rules
/// runs on one serial queue, in the order requests arrived.
final class EnforcerGate: @unchecked Sendable {
    private let enforcer: Enforcer
    private let queue = DispatchQueue(label: "io.github.0xrd.hectord.rules")

    init(_ enforcer: Enforcer) { self.enforcer = enforcer }

    func sync<T>(_ body: (Enforcer) throws -> T) rethrows -> T {
        try queue.sync { try body(enforcer) }
    }

    func async(_ body: @escaping @Sendable (Enforcer) -> Void) {
        queue.async { body(self.enforcer) }
    }
}

func handle(client: Int32, gate: EnforcerGate, dryRun: Bool) {
    // Each read() waits at most 2 s; the whole request must arrive within the deadline.
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    let response: HelperResponse
    if let peer = authorizedPeer(client) {
        do {
            let line = try LineSocket.readLine(from: client, maximumSize: HelperLimits.maximumRequestSize,
                                               deadline: Date().addingTimeInterval(HelperLimits.requestDeadline))
            let request: HelperRequest
            do {
                request = try JSONDecoder.hector.decode(HelperRequest.self, from: line)
            } catch is DecodingError {
                // Most likely an app newer than this helper.
                throw HelperError("hectord \(HectorVersion.current) does not understand this request. "
                                  + "Update the helper from Hector → Blocklists.")
            }
            response = try respond(to: request, peer: peer, gate: gate, dryRun: dryRun)
        } catch {
            log("Request failed: \(error)")
            response = .failure(String(describing: error))
        }
    } else {
        response = .failure("Only administrators can talk to the Hector helper.")
    }
    if let data = try? JSONEncoder.hectorWire.encode(response) {
        try? LineSocket.write(data, to: client)
    }
}

func respond(to request: HelperRequest, peer: uid_t, gate: EnforcerGate, dryRun: Bool) throws -> HelperResponse {
    switch request {
    case .hello:
        return .hello(.current)
    case .snapshot:
        return .snapshot(SocketCollector().snapshot())
    case .processes:
        return .processes(ProcessCollector().snapshot())
    case .backgroundTasks:
        // Fixed path and arguments: nothing from the request reaches the command line.
        guard let output = ToolRunner.live.run("/usr/bin/sfltool", ["dumpbtm"]), output.succeeded else {
            throw HelperError("sfltool dumpbtm failed.")
        }
        return .toolOutput(output.output, truncated: output.truncated)
    case .status:
        return .status(gate.sync { $0.status() })
    case .apply(let blocklist, let authorization):
        try requireAuthorization(authorization, peer: peer, dryRun: dryRun)
        try HelperLimits.validate(blocklist)
        log("Apply requested by uid \(peer).")
        return .status(try gate.sync { try $0.apply(blocklist) })
    case .flush(let authorization):
        try requireAuthorization(authorization, peer: peer, dryRun: dryRun)
        log("Flush requested by uid \(peer).")
        return .status(try gate.sync { try $0.flush() })
    case .refreshHostsLists(let authorization):
        // It makes root download and rewrites /etc/hosts: the same approval as apply.
        try requireAuthorization(authorization, peer: peer, dryRun: dryRun)
        log("Hosts lists refresh requested by uid \(peer).")
        return .status(try gate.sync { try $0.refreshHostsLists() })
    }
}

/// Root may change the rules directly (it could anyway). Everyone else needs an authorization the
/// user granted with their password, so a process merely running as an administrator cannot.
func requireAuthorization(_ authorization: Data, peer: uid_t, dryRun: Bool) throws {
    if peer == 0 || dryRun { return }
    guard HelperAuthorization.verify(authorization) else {
        throw HelperError("Not authorized: changing the firewall needs an administrator's approval.")
    }
}

/// The peer's uid when it is root, the helper's own user, or a member of the admin group; `nil`
/// otherwise. Defense in depth on top of the socket's 0660 root:admin mode.
func authorizedPeer(_ client: Int32) -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0 else { return nil }
    if uid == 0 || uid == geteuid() { return uid }
    guard let user = getpwuid(uid) else { return nil }
    var groups = [Int32](repeating: 0, count: 256)
    var count = Int32(groups.count)
    getgrouplist(user.pointee.pw_name, Int32(bitPattern: user.pointee.pw_gid), &groups, &count)
    return groups.prefix(Int(max(count, 0))).contains(Int32(adminGroupID)) ? uid : nil
}

// MARK: - Install / uninstall

func requireRoot() throws {
    guard geteuid() == 0 else { throw HelperError("This command must run as root (sudo).") }
}

@discardableResult
func launchctl(_ arguments: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func install() throws {
    try requireRoot()
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let destination = HelperPaths.installedBinary
    let logDirectory = (HelperPaths.logFile as NSString).deletingLastPathComponent

    launchctl("bootout", "system/\(HelperPaths.label)")
    replaceLegacyHelper(keepingData: true)
    try SecureFiles.ensureDirectory((destination as NSString).deletingLastPathComponent, mode: 0o755)
    try SecureFiles.ensureDirectory(logDirectory, mode: 0o755)

    if source.path != destination {
        // Copy next to the destination, fix owner and mode, then rename: the daemon path never
        // holds a half-written or user-owned file.
        let staging = destination + ".new"
        unlink(staging)
        try FileManager.default.copyItem(atPath: source.path, toPath: staging)
        removexattr(staging, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard chown(staging, 0, 0) == 0, chmod(staging, 0o755) == 0, rename(staging, destination) == 0 else {
            unlink(staging)
            throw HelperError("Cannot install \(destination): \(String(cString: strerror(errno)))")
        }
    }

    // launchd opens the log as root: create it ourselves, never through a symlink.
    try SecureFiles.createFile(HelperPaths.logFile, mode: 0o644)

    let plist: [String: Any] = [
        "Label": HelperPaths.label,
        "ProgramArguments": [destination, "serve"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardErrorPath": HelperPaths.logFile,
        "ProcessType": "Interactive",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try SecureFiles.write(data, to: HelperPaths.launchDaemonPlist, mode: 0o644)

    try HelperAuthorization.defineRight()
    guard launchctl("bootstrap", "system", HelperPaths.launchDaemonPlist) == 0 else {
        throw HelperError("launchctl bootstrap failed; see \(HelperPaths.logFile)")
    }
    print("Installed \(HelperPaths.label).")
}

/// Stops and removes the Netbite 0.3 helper. When installing (`keepingData`), its data folder
/// becomes Hector's if Hector has none yet, so the blocklist it enforced is re-applied by the new
/// helper at launch; the pf anchor and the hosts section keep their names, so the rules stay in
/// force in between. When uninstalling, its data is deleted.
func replaceLegacyHelper(keepingData: Bool) {
    let files = FileManager.default
    guard files.fileExists(atPath: LegacyPaths.launchDaemonPlist) || files.fileExists(atPath: LegacyPaths.installedBinary)
            || files.fileExists(atPath: LegacyPaths.dataDirectory) else { return }
    launchctl("bootout", "system/\(LegacyPaths.helperLabel)")
    if keepingData, !files.fileExists(atPath: HelperPaths.dataDirectory), files.fileExists(atPath: LegacyPaths.dataDirectory) {
        // Same volume, root-owned on both sides: rename() is atomic and keeps the 0700 mode.
        if rename(LegacyPaths.dataDirectory, HelperPaths.dataDirectory) != 0 {
            log("Could not move \(LegacyPaths.dataDirectory): \(String(cString: strerror(errno)))")
        }
    }
    HelperAuthorization.removeRight(named: LegacyPaths.authorizationRight)
    for path in [LegacyPaths.launchDaemonPlist, LegacyPaths.installedBinary, LegacyPaths.socket, LegacyPaths.logDirectory] {
        try? files.removeItem(atPath: path)
    }
    // Left over when uninstalling, or when Hector already had its own data.
    try? files.removeItem(atPath: LegacyPaths.dataDirectory)
    print("Removed the Netbite helper (\(LegacyPaths.helperLabel)).")
}

func uninstall(purge: Bool) throws {
    try requireRoot()
    // Remove the rules even if the daemon is not running.
    _ = try? Enforcer(root: nil).flush()
    launchctl("bootout", "system/\(HelperPaths.label)")
    HelperAuthorization.removeRight()
    var paths = [HelperPaths.launchDaemonPlist, HelperPaths.installedBinary, HelperPaths.socket, HelperPaths.dataDirectory]
    if purge { paths.append((HelperPaths.logFile as NSString).deletingLastPathComponent) }
    for path in paths {
        try? FileManager.default.removeItem(atPath: path)
    }
    replaceLegacyHelper(keepingData: false)
    print("Uninstalled \(HelperPaths.label). Every Hector rule was removed\(purge ? ", logs included" : "").")
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "serve":
        var root: URL?
        var socketPath = HelperPaths.socket
        var rest = arguments.dropFirst().makeIterator()
        while let arg = rest.next() {
            switch arg {
            case "--dry-run":
                guard let path = rest.next() else { throw HelperError("--dry-run needs a directory.") }
                root = URL(fileURLWithPath: path, isDirectory: true)
            case "--socket":
                guard let path = rest.next() else { throw HelperError("--socket needs a path.") }
                socketPath = path
            default:
                throw HelperError("Unknown option \(arg)")
            }
        }
        if let root {
            // A dry run never touches the system, so it must never run as root.
            guard geteuid() != 0 else { throw HelperError("Do not run a dry run as root.") }
            if socketPath == HelperPaths.socket { socketPath = root.appending(path: "hectord.sock").path }
        } else {
            try requireRoot()
        }
        try await serve(dryRunRoot: root, socketPath: socketPath)
    case "install": try install()
    case "uninstall": try uninstall(purge: arguments.dropFirst().contains("--purge"))
    case "version", "--version": print("hectord \(HectorVersion.current)")
    default: print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("hectord: \(LogText.sanitized(String(describing: error)))\n".utf8))
    exit(1)
}
