import Foundation

public enum TransportProtocol: String, Codable, Sendable {
    case tcp
    case udp
}

/// One open internet socket of a process.
public struct SocketInfo: Codable, Hashable, Sendable {
    public var transport: TransportProtocol
    public var localAddress: IPAddress?
    public var localPort: UInt16
    public var remoteAddress: IPAddress?
    public var remotePort: UInt16
    /// TCP state name (`ESTABLISHED`, `SYN_SENT`…); `nil` for UDP.
    public var tcpState: String?

    public init(transport: TransportProtocol, localAddress: IPAddress?, localPort: UInt16,
                remoteAddress: IPAddress?, remotePort: UInt16, tcpState: String?) {
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.tcpState = tcpState
    }

    /// Connected to a remote peer (as opposed to listening or unbound).
    public var hasRemote: Bool { remoteAddress != nil && remotePort != 0 }
}

/// The process that owns sockets, plus the app bundle it lives in when there is one.
public struct NetProcess: Codable, Hashable, Sendable {
    public var pid: Int32
    /// Kernel process name (`Google Chrome Helper`, `mDNSResponder`…).
    public var name: String
    public var executablePath: String?
    /// Outermost `.app` bundle containing the executable, so helpers group under their app.
    public var appBundleIdentifier: String?
    public var appName: String?
    /// Path of that outermost `.app` bundle.
    public var appBundlePath: String?

    public init(pid: Int32, name: String, executablePath: String?, appBundleIdentifier: String?,
                appName: String?, appBundlePath: String? = nil) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.appBundleIdentifier = appBundleIdentifier
        self.appName = appName
        self.appBundlePath = appBundlePath
    }

    /// Name to show in a list: the app when known, else the process name.
    /// The app's name, else the process name; a name that is only a version (from an older
    /// helper) gives way to its folder's name, as `SocketCollector.displayName` does.
    public var displayName: String {
        appName ?? SocketCollector.displayName(kernelName: name, path: executablePath) ?? name
    }
}

public struct ProcessSockets: Codable, Sendable {
    public var process: NetProcess
    public var sockets: [SocketInfo]
}

public struct CollectorSnapshot: Codable, Sendable {
    public var takenAt: Date
    public var processes: [ProcessSockets]
    /// Processes whose sockets could not be read (owned by another user). Run as root to see them.
    public var unreadableProcessCount: Int

    public var socketCount: Int { processes.reduce(0) { $0 + $1.sockets.count } }
}
