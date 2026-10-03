import Darwin
import Foundation
import NetbiteCore

// netbited: the only part of Netbite that runs as root. It enforces a blocklist with pf and
// /etc/hosts and answers the app over a Unix socket that only administrators can open.
// See SECURITY.md for the threat model.

let usage = """
netbited \(NetbiteVersion.current): the Netbite privileged helper.

USAGE
  netbited serve                  Run the helper (started by launchd)
  netbited serve --dry-run DIR [--socket PATH]
                                  Run without root: paths live under DIR, commands are only logged,
                                  and requests are not checked for an authorization
  netbited install                Install as a LaunchDaemon (run as root)
  netbited uninstall [--purge]    Remove every rule, then the LaunchDaemon (run as root);
                                  --purge also deletes the helper's logs
  netbited version
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
    log("netbited \(NetbiteVersion.current) listening on \(socketPath)\(dryRunRoot.map { " (dry run in \($0.path))" } ?? "")")

    while true {
        let client = accept(server, nil, nil)
        guard client >= 0 else { continue }
        await handle(client: client, enforcer: enforcer, dryRun: dryRunRoot != nil)
        close(client)
    }
}

func handle(client: Int32, enforcer: Enforcer, dryRun: Bool) async {
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
            let request = try JSONDecoder.netbite.decode(HelperRequest.self, from: line)
            switch request {
            case .status:
                response = .status(enforcer.status())
            case .snapshot:
                response = .snapshot(SocketCollector().snapshot())
            case .apply(let blocklist, let authorization):
                try requireAuthorization(authorization, peer: peer, dryRun: dryRun)
                try HelperLimits.validate(blocklist)
                log("Apply requested by uid \(peer).")
                response = .status(try enforcer.apply(blocklist))
            case .flush(let authorization):
                try requireAuthorization(authorization, peer: peer, dryRun: dryRun)
                log("Flush requested by uid \(peer).")
                response = .status(try enforcer.flush())
            }
        } catch {
            log("Request failed: \(error)")
            response = .failure(String(describing: error))
        }
    } else {
        response = .failure("Only administrators can talk to the Netbite helper.")
    }
    if let data = try? JSONEncoder.netbiteWire.encode(response) {
        try? LineSocket.write(data, to: client)
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
    print("Uninstalled \(HelperPaths.label). Every Netbite rule was removed\(purge ? ", logs included" : "").")
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
            if socketPath == HelperPaths.socket { socketPath = root.appending(path: "netbited.sock").path }
        } else {
            try requireRoot()
        }
        try await serve(dryRunRoot: root, socketPath: socketPath)
    case "install": try install()
    case "uninstall": try uninstall(purge: arguments.dropFirst().contains("--purge"))
    case "version", "--version": print("netbited \(NetbiteVersion.current)")
    default: print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("netbited: \(LogText.sanitized(String(describing: error)))\n".utf8))
    exit(1)
}
