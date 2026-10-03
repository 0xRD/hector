import Darwin
import Foundation

/// One running process, in the spirit of TaskExplorer.
public struct RunningProcess: Codable, Hashable, Identifiable, Sendable {
    public var pid: Int32
    /// 0 when the parent is unknown (the kernel, or a process that could not be read).
    public var parentPID: Int32
    public var userID: UInt32
    public var userName: String?
    /// Kernel process name.
    public var name: String
    public var executablePath: String?
    /// Full argument vector including `argv[0]`; empty when it could not be read (another user's
    /// process without root).
    public var arguments: [String]
    public var startedAt: Date?
    /// Outermost `.app` bundle containing the executable, so helpers show under their app.
    public var appBundlePath: String?
    public var appName: String?
    /// Connected internet sockets; `nil` when the process's descriptors could not be read.
    public var connections: [SocketInfo]?

    public var id: Int32 { pid }

    public init(pid: Int32, parentPID: Int32, userID: UInt32, userName: String? = nil, name: String,
                executablePath: String? = nil, arguments: [String] = [], startedAt: Date? = nil,
                appBundlePath: String? = nil, appName: String? = nil, connections: [SocketInfo]? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.userName = userName
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.startedAt = startedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.appBundlePath = appBundlePath
        self.appName = appName
        self.connections = connections
    }

    /// Name to show in a list: the app when known, else the process name.
    public var displayName: String { appName ?? name }
}

/// The result of `ProcessCollector.snapshot()`.
public struct ProcessSnapshot: Codable, Sendable {
    public var takenAt: Date
    /// Sorted by PID.
    public var processes: [RunningProcess]
    /// The collector ran as root, so arguments and sockets of every user are included.
    public var ranAsRoot: Bool

    public init(takenAt: Date, processes: [RunningProcess], ranAsRoot: Bool) {
        self.takenAt = takenAt
        self.processes = processes
        self.ranAsRoot = ranAsRoot
    }
}

/// Lists running processes through libproc and sysctl. Nothing is executed.
///
/// As a normal user every process is listed with its name, path, parent and owner; arguments and
/// sockets are readable only for the user's own processes. As root (the helper) everything is.
public struct ProcessCollector: Sendable {
    public init() {}

    public func snapshot() -> ProcessSnapshot {
        var userNames: [UInt32: String] = [:]
        var bundles: [String: SocketCollector.AppBundle] = [:]
        var processes: [RunningProcess] = []

        for pid in SocketCollector.allPIDs() where pid > 0 {
            guard let info = Self.bsdInfo(of: pid) else { continue }
            let path = SocketCollector.executablePath(of: pid)
            var bundle = SocketCollector.AppBundle()
            if let path {
                if let cached = bundles[path] {
                    bundle = cached
                } else {
                    bundle = SocketCollector.appBundle(containing: path)
                    bundles[path] = bundle
                }
            }
            let uid = info.pbi_uid
            if userNames[uid] == nil, let entry = getpwuid(uid) {
                userNames[uid] = String(cString: entry.pointee.pw_name)
            }
            let sockets = SocketCollector.fileDescriptors(of: pid).map { fds in
                fds.filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
                    .compactMap { SocketCollector.socketInfo(pid: pid, fd: $0.proc_fd) }
                    .filter(\.hasRemote)
            }
            let name = SocketCollector.name(of: pid) ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)"
            let started = info.pbi_start_tvsec > 0
                ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)) : nil
            processes.append(RunningProcess(
                pid: pid, parentPID: Int32(bitPattern: info.pbi_ppid), userID: uid, userName: userNames[uid],
                name: name, executablePath: path, arguments: Self.arguments(of: pid)?.arguments ?? [],
                startedAt: started, appBundlePath: bundle.path, appName: bundle.name, connections: sockets
            ))
        }
        processes.sort { $0.pid < $1.pid }
        return ProcessSnapshot(takenAt: Date(), processes: processes, ranAsRoot: geteuid() == 0)
    }

    static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// The executable path the kernel recorded at exec time and the argument vector.
    static func arguments(of pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return parseProcArgs2(buffer.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer: `argc` as a native 32-bit integer, the executable path,
    /// NUL padding, then `argc` NUL-terminated arguments (the environment follows and is ignored:
    /// it may hold secrets and is never read).
    static func parseProcArgs2<Bytes: Collection>(_ bytes: Bytes) -> (executable: String, arguments: [String])?
    where Bytes.Element == UInt8 {
        let data = Array(bytes)
        guard data.count >= 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        guard argc >= 0, argc < 1 << 16 else { return nil }

        var index = 4
        func readString() -> String? {
            guard index < data.count, let end = data[index...].firstIndex(of: 0) else { return nil }
            let string = String(decoding: data[index..<end], as: UTF8.self)
            index = end + 1
            return string
        }
        guard let executable = readString() else { return nil }
        while index < data.count, data[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard let argument = readString() else { break }
            arguments.append(argument)
        }
        return (executable, arguments)
    }
}

// MARK: - What deserves a second look

/// Reasons a process deserves a second look, as TaskExplorer and KnockKnock flag them.
public enum ProcessFlag: String, Codable, CaseIterable, Comparable, Sendable {
    /// The executable no longer exists on disk: it was deleted or replaced after it started.
    case deletedExecutable
    /// Runs from `/tmp`, `/private/var/folders` or another temporary folder.
    case temporaryFolder
    /// Runs from a Downloads folder.
    case downloads
    /// The executable or a folder above it is hidden: its name starts with a dot.
    case hiddenPath

    public var label: String {
        switch self {
        case .deletedExecutable: "Executable deleted"
        case .temporaryFolder: "Runs from a temporary folder"
        case .downloads: "Runs from Downloads"
        case .hiddenPath: "Hidden file or folder"
        }
    }

    public static func < (lhs: ProcessFlag, rhs: ProcessFlag) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    private static let temporaryPrefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/",
                                            "/var/folders/", "/private/var/folders/"]

    /// Flags that follow from the path alone. `exists` is injectable for tests.
    public static func flags(forExecutable path: String?,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Set<ProcessFlag> {
        guard let path, path.hasPrefix("/") else { return [] }
        var flags: Set<ProcessFlag> = []
        if !exists(path) { flags.insert(.deletedExecutable) }
        if temporaryPrefixes.contains(where: path.hasPrefix) { flags.insert(.temporaryFolder) }
        let components = path.split(separator: "/").map(String.init)
        // /Users/<name>/Downloads/… for any user, as the helper sees every user's processes.
        if components.count > 3, components[0] == "Users", components[2] == "Downloads" { flags.insert(.downloads) }
        if components.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) {
            flags.insert(.hiddenPath)
        }
        return flags
    }
}
