import Foundation

/// Which apps macOS shows behind the green camera and orange microphone indicators.
///
/// Control Center logs each change of the indicators as
/// `Active activity attributions changed to ["cam:com.apple.PhotoBooth", "loc:…"]`, with public
/// bundle identifiers. A normal user can read that log with `/usr/bin/log`, without a prompt or a
/// permission. It is not an API: the message may change with macOS, in which case the cameras
/// fall back to "app unknown" and nothing else breaks.
///
/// Any process can log under any subsystem name, so a message counts only if the system says it
/// came from Control Center's own executable; otherwise an app could blame another for its use
/// of the camera.
public enum SensorIndicatorLog {
    static let controlCenterPath = "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
    static let messagePrefix = "Active activity attributions changed to "
    static let predicate = #"subsystem == "com.apple.controlcenter" AND category == "sensor-indicators" AND process == "ControlCenter" AND eventMessage BEGINSWITH "Active activity attributions changed to ""#

    /// Bundle identifiers per kind of sensor, from one indicator message; `nil` for any other
    /// message. Location and other sensors are ignored.
    public static func attributions(fromMessage message: String) -> [CaptureDeviceKind: [String]]? {
        guard message.hasPrefix(messagePrefix) else { return nil }
        let list = message.dropFirst(messagePrefix.count).trimmingCharacters(in: .whitespaces)
        guard list.hasPrefix("["), list.hasSuffix("]") else { return nil }
        var result: [CaptureDeviceKind: [String]] = [.camera: [], .microphone: []]
        for entry in list.dropFirst().dropLast().split(separator: ",") {
            let item = entry.trimmingCharacters(in: .whitespaces)
            guard item.count > 2, item.hasPrefix("\""), item.hasSuffix("\"") else { continue }
            let parts = item.dropFirst().dropLast().split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, isBundleIdentifier(parts[1]) else { continue }
            switch parts[0] {
            case "cam": if !result[.camera]!.contains(parts[1]) { result[.camera]!.append(parts[1]) }
            case "mic": if !result[.microphone]!.contains(parts[1]) { result[.microphone]!.append(parts[1]) }
            default: continue
            }
        }
        return result
    }

    /// Attributions from one line of `log --style ndjson`, if it is an indicator message sent by
    /// Control Center itself.
    public static func attributions(fromLogLine line: Substring) -> [CaptureDeviceKind: [String]]? {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["processImagePath"] as? String == controlCenterPath,
              let message = object["eventMessage"] as? String else { return nil }
        return attributions(fromMessage: message)
    }

    static func isBundleIdentifier(_ value: String) -> Bool {
        guard (1...255).contains(value.utf8.count), let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The latest attributions in the last `window`, or `nil` when the log could not be read or
    /// had no indicator change in that time. Blocks while `log show` runs (a fraction of a second
    /// for a few minutes of log).
    public static func latest(within window: Duration = .seconds(600)) -> [CaptureDeviceKind: [String]]? {
        let seconds = max(1, Int(window.components.seconds))
        guard let output = run(["show", "--last", "\(seconds)s", "--style", "ndjson", "--predicate", predicate]) else { return nil }
        return output.split(separator: "\n").reversed().lazy.compactMap { attributions(fromLogLine: $0) }.first
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Running processes of these apps, one per bundle identifier (the lowest PID, normally the
    /// app itself rather than a helper). Apps no longer running are left out.
    public static func processes(forBundleIdentifiers identifiers: [String]) -> [ProcessIdentity] {
        guard !identifiers.isEmpty else { return [] }
        var found: [String: ProcessIdentity] = [:]
        for pid in SocketCollector.allPIDs().sorted() where pid > 0 {
            guard let path = SocketCollector.executablePath(of: pid), path.contains(".app/") else { continue }
            let bundle = SocketCollector.appBundle(containing: path)
            guard let identifier = bundle.identifier, identifiers.contains(identifier), found[identifier] == nil else { continue }
            found[identifier] = ProcessIdentity.resolve(pid: pid)
        }
        return identifiers.compactMap { found[$0] }
    }
}

/// Follows Control Center's indicator messages as they are logged, through `log stream`.
///
/// `handler` runs on the main actor with the bundle identifiers per sensor after each change. The
/// last change of the previous ten minutes is read first, so an app already using the camera when
/// monitoring starts is named too. Call `stop()` to end the `log` process.
public final class SensorIndicatorWatcher: @unchecked Sendable {
    public typealias Handler = @MainActor ([CaptureDeviceKind: [String]]) -> Void

    private let handler: Handler
    private let lock = NSLock()
    private var process: Process?
    private var lifeline: FileHandle?
    private var buffer = Data()
    /// Set once a streamed change arrived, so the slower look-back never overrides it.
    private var hasStreamed = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Whether `log stream` could be started.
    @discardableResult
    public func start() -> Bool {
        // `log stream` outlives a killed parent. The shell holds the read end of `lifeline` and
        // stops it as soon as the pipe closes, which happens when Hector exits in any way.
        // Arguments go through "$@", never into the script text.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/log \"$@\" & child=$!; read -r _; kill $child 2>/dev/null", "hector-indicators",
                             "stream", "--style", "ndjson", "--predicate", SensorIndicatorLog.predicate]
        let pipe = Pipe()
        let lifeline = Pipe()
        process.standardOutput = pipe
        process.standardInput = lifeline
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        do { try process.run() } catch { return false }
        lock.withLock {
            self.process = process
            self.lifeline = lifeline.fileHandleForWriting
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let latest = SensorIndicatorLog.latest() else { return }
            guard let self, !self.lock.withLock({ self.hasStreamed }) else { return }
            self.deliver(latest)
        }
        return true
    }

    public func stop() {
        let (process, lifeline) = lock.withLock { () -> (Process?, FileHandle?) in
            defer { self.process = nil; self.lifeline = nil }
            return (self.process, self.lifeline)
        }
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // Closing the lifeline makes the shell stop `log stream`, then exit.
        try? lifeline?.close()
    }

    deinit { stop() }

    private func receive(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            // A runaway line (no newline for 1 MB) is not an indicator message: drop it.
            if buffer.count > 1 << 20 { buffer.removeAll() }
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines {
            guard let attributions = SensorIndicatorLog.attributions(fromLogLine: Substring(String(decoding: line, as: UTF8.self))) else { continue }
            lock.withLock { hasStreamed = true }
            deliver(attributions)
        }
    }

    private func deliver(_ attributions: [CaptureDeviceKind: [String]]) {
        let handler = handler
        Task { @MainActor in handler(attributions) }
    }
}
