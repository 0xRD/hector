import Darwin
import Foundation

/// What an external tool printed.
public struct ToolOutput: Sendable {
    public var status: Int32
    public var output: String
    public var errorOutput: String
    /// The tool was killed after the timeout; `output` holds what it printed until then.
    public var timedOut: Bool
    /// The tool printed more than the cap; the rest was discarded.
    public var truncated: Bool

    public init(status: Int32 = 0, output: String, errorOutput: String = "", timedOut: Bool = false, truncated: Bool = false) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
        self.timedOut = timedOut
        self.truncated = truncated
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs the system tools the persistence scanner reads (`launchctl`, `systemextensionsctl`…).
///
/// Injectable so tests can feed sample output without touching the machine.
public struct ToolRunner: Sendable {
    /// Returns `nil` when the tool is missing or could not be started.
    public var run: @Sendable (_ executable: String, _ arguments: [String]) -> ToolOutput?

    public init(run: @escaping @Sendable (_ executable: String, _ arguments: [String]) -> ToolOutput?) {
        self.run = run
    }

    /// Runs nothing; every tool looks absent.
    public static let none = ToolRunner { _, _ in nil }

    public static let live = ToolRunner { executable, arguments in
        ProcessTool.run(executable, arguments)
    }
}

enum ProcessTool {
    static let timeout: TimeInterval = 10
    static let outputCap = 8 << 20

    /// Runs `executable` directly (never through a shell) with an argument array, a minimal
    /// environment and no stdin, so nothing found on disk can be injected into a command line and
    /// a tool that asks a question fails instead of hanging.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = timeout,
                    cap: Int = outputCap) -> ToolOutput? {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // No DYLD_* or user PATH leaks into the tools, and C locale keeps their output parseable.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
                               "HOME": NSHomeDirectory()]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let out = CappedReader(cap: cap)
        let err = CappedReader(cap: 64 << 10)
        let readers = DispatchGroup()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }
        out.drain(stdout.fileHandleForReading, group: readers)
        err.drain(stderr.fileHandleForReading, group: readers)

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A grandchild may still hold the pipe open; do not wait for it forever.
        _ = readers.wait(timeout: .now() + 2)

        return ToolOutput(status: process.terminationStatus, output: out.string, errorOutput: err.string,
                          timedOut: timedOut, truncated: out.truncated)
    }
}

/// Reads a pipe to EOF on a background queue, keeping at most `cap` bytes. It keeps reading past
/// the cap so the child never blocks on a full pipe.
private final class CappedReader: @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var data = Data()
    private var overflowed = false

    init(cap: Int) { self.cap = cap }

    func drain(_ handle: FileHandle, group: DispatchGroup) {
        DispatchQueue.global(qos: .utility).async(group: group) { [self] in
            while let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
                lock.withLock {
                    let room = cap - data.count
                    if chunk.count > room { overflowed = true }
                    if room > 0 { data.append(chunk.prefix(room)) }
                }
            }
        }
    }

    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    var truncated: Bool { lock.withLock { overflowed } }
}
