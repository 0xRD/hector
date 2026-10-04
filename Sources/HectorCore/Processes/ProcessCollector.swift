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
    /// What the helper may show to the user `peer`: every process, but command-line arguments only
    /// for that user's own processes and the system's (root). macOS hides other users' arguments
    /// from everyone but root, and they can hold passwords or tokens; an administrator account
    /// must not read them through the helper without a password. Root sees everything.
    public func visible(to peer: UInt32) -> ProcessSnapshot {
        guard peer != 0 else { return self }
        var copy = self
        for index in copy.processes.indices where copy.processes[index].userID != peer && copy.processes[index].userID != 0 {
            copy.processes[index].arguments = []
        }
        return copy
    }

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

extension ProcessSnapshot {
    /// Processes depth-first under their parents, each with its depth in the tree. A process whose
    /// parent is not in the snapshot is a root; siblings keep their PID order.
    public func treeOrdered() -> [(process: RunningProcess, depth: Int)] {
        let pids = Set(processes.map(\.pid))
        var children: [Int32: [RunningProcess]] = [:]
        var roots: [RunningProcess] = []
        for process in processes {
            if process.parentPID != process.pid, pids.contains(process.parentPID) {
                children[process.parentPID, default: []].append(process)
            } else {
                roots.append(process)
            }
        }
        var ordered: [(process: RunningProcess, depth: Int)] = []
        var visited: Set<Int32> = []
        // Iterative, so a deep or malformed parent chain cannot overflow the stack.
        var stack = roots.reversed().map { ($0, 0) }
        while let (process, depth) = stack.popLast() {
            guard visited.insert(process.pid).inserted else { continue }
            ordered.append((process, depth))
            for child in (children[process.pid] ?? []).reversed() { stack.append((child, depth + 1)) }
        }
        // A parent cycle has no root: list what is left flat rather than dropping it.
        for process in processes where !visited.contains(process.pid) { ordered.append((process, 0)) }
        return ordered
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
            guard let info = Self.basicInfo(of: pid) else { continue }
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
            let uid = info.userID
            if userNames[uid] == nil, let entry = getpwuid(uid) {
                userNames[uid] = String(cString: entry.pointee.pw_name)
            }
            let sockets = SocketCollector.fileDescriptors(of: pid).map { fds in
                fds.filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
                    .compactMap { SocketCollector.socketInfo(pid: pid, fd: $0.proc_fd) }
                    .filter(\.hasRemote)
            }
            let name = SocketCollector.processName(of: pid, path: path)
            processes.append(RunningProcess(
                pid: pid, parentPID: info.parentPID, userID: uid, userName: userNames[uid],
                name: name, executablePath: path, arguments: Self.arguments(of: pid)?.arguments ?? [],
                startedAt: info.startedAt, appBundlePath: bundle.path, appName: bundle.name, connections: sockets
            ))
        }
        processes.sort { $0.pid < $1.pid }
        return ProcessSnapshot(takenAt: Date(), processes: processes, ranAsRoot: geteuid() == 0)
    }

    struct BasicInfo {
        var parentPID: Int32
        var userID: UInt32
        var startedAt: Date?
    }

    /// Parent, owner and start time. libproc refuses other users' processes unless root, so fall
    /// back on `sysctl(KERN_PROC_PID)`, which `ps` uses and which works for every process.
    static func basicInfo(of pid: pid_t) -> BasicInfo? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size {
            return BasicInfo(parentPID: Int32(bitPattern: bsd.pbi_ppid), userID: bsd.pbi_uid,
                             startedAt: date(seconds: Int(bsd.pbi_start_tvsec)))
        }
        var kinfo = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &length, nil, 0) == 0, length == MemoryLayout<kinfo_proc>.stride,
              kinfo.kp_proc.p_pid == pid else { return nil }
        return BasicInfo(parentPID: kinfo.kp_eproc.e_ppid, userID: kinfo.kp_eproc.e_ucred.cr_uid,
                         startedAt: date(seconds: Int(kinfo.kp_proc.p_un.__p_starttime.tv_sec)))
    }

    private static func date(seconds: Int) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
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

    /// Why the flag deserves attention, in one sentence.
    public var explanation: String {
        switch self {
        case .deletedExecutable: "The file this process started from is gone: it was deleted or replaced while running."
        case .temporaryFolder: "Installers do this; malware too, because temporary folders are writable by anyone."
        case .downloads: "Apps usually run from Applications; code started from Downloads was never installed."
        case .hiddenPath: "Something in the path is hidden from Finder, a common way to stay unnoticed."
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
