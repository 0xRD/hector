import Darwin
import Foundation

/// Who a process is, as far as a privacy screen needs: its name, executable and app.
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    /// Kernel process name, or the executable's file name, or "pid N" when neither can be read.
    public var name: String
    public var executablePath: String?
    /// Outermost `.app` bundle containing the executable, so helpers show under their app.
    public var appBundlePath: String?
    public var appName: String?
    public var bundleIdentifier: String?

    public init(pid: Int32, name: String, executablePath: String? = nil, appBundlePath: String? = nil,
                appName: String? = nil, bundleIdentifier: String? = nil) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }

    /// Name to show: the app when known, else the process name.
    public var displayName: String { appName ?? name }

    /// Reads a running process through libproc, the same calls the process list uses.
    /// `proc_pidpath` works for other users' processes without root. A process that is gone, or
    /// whose path cannot be read, keeps its PID and a placeholder name.
    public static func resolve(pid: Int32) -> ProcessIdentity {
        let path = SocketCollector.executablePath(of: pid)
        let fileName = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        let name = SocketCollector.name(of: pid) ?? fileName ?? "pid \(pid)"
        guard let path else { return ProcessIdentity(pid: pid, name: name) }
        let bundle = SocketCollector.appBundle(containing: path)
        return ProcessIdentity(pid: pid, name: name, executablePath: path, appBundlePath: bundle.path,
                               appName: bundle.name, bundleIdentifier: bundle.identifier)
    }
}
