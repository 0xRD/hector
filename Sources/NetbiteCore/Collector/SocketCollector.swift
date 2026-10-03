import Darwin
import Foundation

/// Lists the internet sockets of every process through libproc.
///
/// This is the same source `lsof -i` uses. It needs no entitlement; as a normal user it sees the
/// user's own processes, as root it sees all of them.
public struct SocketCollector: Sendable {
    /// Also report listening and unconnected sockets.
    public var includeUnconnected: Bool

    public init(includeUnconnected: Bool = false) {
        self.includeUnconnected = includeUnconnected
    }

    public func snapshot() -> CollectorSnapshot {
        var processes: [ProcessSockets] = []
        var unreadable = 0
        var bundleCache: [String: (id: String?, name: String?)] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            guard let fds = Self.fileDescriptors(of: pid) else {
                unreadable += 1
                continue
            }
            let sockets = fds
                .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
                .compactMap { Self.socketInfo(pid: pid, fd: $0.proc_fd) }
                .filter { includeUnconnected || $0.hasRemote }
            guard !sockets.isEmpty else { continue }

            let path = Self.executablePath(of: pid)
            var bundle: (id: String?, name: String?) = (nil, nil)
            if let path {
                if let cached = bundleCache[path] {
                    bundle = cached
                } else {
                    bundle = Self.appBundle(containing: path)
                    bundleCache[path] = bundle
                }
            }
            let name = Self.name(of: pid) ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)"
            let process = NetProcess(pid: pid, name: name, executablePath: path,
                                     appBundleIdentifier: bundle.id, appName: bundle.name)
            processes.append(ProcessSockets(process: process, sockets: sockets))
        }

        processes.sort {
            $0.process.displayName.localizedCaseInsensitiveCompare($1.process.displayName) == .orderedAscending
        }
        return CollectorSnapshot(takenAt: Date(), processes: processes, unreadableProcessCount: unreadable)
    }

    // MARK: - libproc

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        return Array(pids.prefix(max(0, Int(count))))
    }

    static func fileDescriptors(of pid: pid_t) -> [proc_fdinfo]? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Leave room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return nil }
        return Array(fds.prefix(Int(filled) / stride))
    }

    static func socketInfo(pid: pid_t, fd: Int32) -> SocketInfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }

        let family = info.psi.soi_family
        guard family == AF_INET || family == AF_INET6 else { return nil }

        let transport: TransportProtocol
        let endpoints: in_sockinfo
        var state: String?
        switch info.psi.soi_kind {
        case Int32(SOCKINFO_TCP):
            transport = .tcp
            endpoints = info.psi.soi_proto.pri_tcp.tcpsi_ini
            state = tcpStateName(info.psi.soi_proto.pri_tcp.tcpsi_state)
        case Int32(SOCKINFO_IN) where info.psi.soi_protocol == IPPROTO_UDP:
            transport = .udp
            endpoints = info.psi.soi_proto.pri_in
        default:
            return nil
        }

        let isV4 = endpoints.insi_vflag & UInt8(INI_IPV4) != 0
        return SocketInfo(
            transport: transport,
            localAddress: address(v4: endpoints.insi_laddr.ina_46.i46a_addr4, v6: endpoints.insi_laddr.ina_6, isV4: isV4),
            localPort: port(endpoints.insi_lport),
            remoteAddress: address(v4: endpoints.insi_faddr.ina_46.i46a_addr4, v6: endpoints.insi_faddr.ina_6, isV4: isV4),
            remotePort: port(endpoints.insi_fport),
            tcpState: state
        )
    }

    /// Ports are stored in network byte order in the low 16 bits of an `Int32`.
    private static func port(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    /// The kernel stores both families in a union; `insi_vflag` says which half is meaningful.
    private static func address(v4: in_addr, v6: in6_addr, isV4: Bool) -> IPAddress? {
        let address = (isV4 ? IPAddress(v4) : IPAddress(v6)).normalized
        switch address {
        case .v4(0), .v6(0): return nil
        default: return address
        }
    }

    private static func tcpStateName(_ state: Int32) -> String {
        let names = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT",
                     "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]
        return names.indices.contains(Int(state)) ? names[Int(state)] : "STATE_\(state)"
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The outermost `.app` in `path`: `/Applications/Google Chrome.app/…/Google Chrome Helper.app/…`
    /// resolves to Google Chrome, so helpers are grouped under the app the user knows.
    static func appBundle(containing path: String) -> (id: String?, name: String?) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return (nil, nil) }
        let appPath = components[...index].joined(separator: "/")
        let fallbackName = String(components[index].dropLast(4))
        guard let bundle = Bundle(path: appPath) else { return (nil, fallbackName) }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fallbackName
        return (bundle.bundleIdentifier, name)
    }
}
