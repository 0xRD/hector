import Darwin
import Foundation
import HectorCore

/// Downloads run in a child process that is not root.
///
/// Fetching a hosts list or the country database means TLS, HTTP, redirects, gzip and parsing
/// files written by third parties. None of that needs root, so the helper starts itself again
/// (`hectord fetch-list` or `hectord fetch-countries`); the child gives up root for `nobody`
/// before anything else, with a fixed environment and a private temporary folder, and writes its
/// result to standard output. The helper reads that output with a size and time limit, checks
/// every domain or range again, and only then writes anything as root.
enum Unprivileged {
    /// `nobody` on macOS.
    static let nobodyUser: uid_t = 4_294_967_294
    static let nobodyGroup: gid_t = 4_294_967_294

    /// Hosts lists are at most 16 MB of text; their JSON form stays well under this.
    static let maximumListOutput = 48 * 1024 * 1024
    /// The country CSV is about 30 MB.
    static let maximumCountriesOutput = 256 * 1024 * 1024

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The child's view of a list download, as JSON on standard output.
    struct ListResult: Codable {
        var notModified = false
        var domains: [String] = []
        var invalidLines = 0
        var skippedEntries = 0
        var exceededLimit = false
        var etag: String?
        var lastModified: String?
    }

    // MARK: - Child side

    /// First thing a child does. As root: drop every group, then the group and user IDs, and
    /// make sure root cannot be taken back. Not root (a dry run): nothing to drop.
    static func dropPrivileges() throws {
        guard geteuid() == 0 || getuid() == 0 else { return }
        var group = nobodyGroup
        guard setgroups(1, &group) == 0, setgid(nobodyGroup) == 0, setegid(nobodyGroup) == 0,
              setuid(nobodyUser) == 0, seteuid(nobodyUser) == 0 else {
            throw Failure(description: "Could not give up root.")
        }
        guard getuid() == nobodyUser, geteuid() == nobodyUser, getgid() == nobodyGroup,
              setuid(0) != 0, seteuid(0) != 0 else {
            throw Failure(description: "Root could be taken back; stopping.")
        }
    }

    /// `hectord fetch-list ID [--etag VALUE] [--last-modified VALUE]`
    static func runListChild(_ arguments: [String]) async throws {
        try dropPrivileges()
        var rest = arguments.makeIterator()
        guard let id = rest.next(), let source = HostsListCatalog.source(id) else { throw Failure(description: "Unknown list.") }
        var etag: String?
        var lastModified: String?
        while let flag = rest.next() {
            guard let value = rest.next().flatMap(HostsListDownloader.validator) else { throw Failure(description: "Bad option.") }
            switch flag {
            case "--etag": etag = value
            case "--last-modified": lastModified = value
            default: throw Failure(description: "Unknown option.")
            }
        }
        var result = ListResult()
        switch try await HostsListDownloader.fetch(source, etag: etag, lastModified: lastModified) {
        case .notModified:
            result.notModified = true
        case .downloaded(let parsed, let newETag, let newLastModified):
            result.domains = parsed.domains
            result.invalidLines = parsed.invalidLines
            result.skippedEntries = parsed.skippedEntries
            result.exceededLimit = parsed.exceededLimit
            result.etag = newETag
            result.lastModified = newLastModified
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(result))
    }

    /// `hectord fetch-countries`: the validated CSV on standard output.
    static func runCountriesChild() async throws {
        try dropPrivileges()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let destination = folder.appending(path: "countries-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await GeoIPUpdater.update(to: destination)
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            FileHandle.standardOutput.write(chunk)
        }
    }

    // MARK: - Helper side

    /// Downloads and parses `source` in a child, then validates its domains again here.
    static func hostsList(_ source: HostsListSource, etag: String?, lastModified: String?) throws -> HostsListDownloader.Outcome {
        var arguments = ["fetch-list", source.id]
        if let etag = etag.flatMap(HostsListDownloader.validator) { arguments += ["--etag", etag] }
        if let lastModified = lastModified.flatMap(HostsListDownloader.validator) { arguments += ["--last-modified", lastModified] }
        let output = try runChild(arguments, maximumOutput: maximumListOutput,
                                  timeout: HostsListCatalog.resourceTimeout + 30)
        let result = try JSONDecoder().decode(ListResult.self, from: output)
        if result.notModified { return .notModified }
        // The same strict parser the child used, on plain names: anything that is not a valid
        // domain is dropped here, whatever the child said.
        let text = result.domains.prefix(HostsListCatalog.maximumDomainsPerList).joined(separator: "\n")
        var parsed = HostsListParser.parse(Data(text.utf8))
        guard parsed.domains.count >= source.minimumDomains else {
            throw HostsListDownloader.DownloadError.implausible(domains: parsed.domains.count, minimum: source.minimumDomains)
        }
        parsed.invalidLines += max(0, min(result.invalidLines, 10_000_000))
        parsed.skippedEntries += max(0, min(result.skippedEntries, 10_000_000))
        parsed.exceededLimit = parsed.exceededLimit || result.exceededLimit
        return .downloaded(parsed, etag: result.etag.flatMap(HostsListDownloader.validator),
                           lastModified: result.lastModified.flatMap(HostsListDownloader.validator))
    }

    /// Downloads the country database in a child and returns its CSV, already validated by the
    /// child; the caller writes it and parses it again before use.
    static func countriesCSV() throws -> Data {
        try runChild(["fetch-countries"], maximumOutput: maximumCountriesOutput, timeout: 900)
    }

    /// Starts this executable with `arguments`, a fixed environment and a private temporary
    /// folder owned by the child's user, and returns its standard output. Throws when it fails,
    /// writes too much, or takes too long.
    private static func runChild(_ arguments: [String], maximumOutput: Int, timeout: TimeInterval) throws -> Data {
        guard let executable = Bundle.main.executablePath else { throw Failure(description: "Cannot find hectord.") }
        let scratch = try privateFolder()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Nothing inherited: no DYLD_* or proxy variables from wherever the helper came from.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": scratch + "/", "HOME": scratch,
                               "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: scratch, isDirectory: true)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = OutputCollector(limit: maximumOutput)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if !collector.append(data), process.isRunning { process.terminate() }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw Failure(description: "The download took too long.")
        }
        // Whatever is still buffered in the pipe.
        stdout.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stdout.fileHandleForReading.readToEnd(), !collector.append(rest) {
            throw Failure(description: "The download produced more data than allowed.")
        }
        guard !collector.overflowed else { throw Failure(description: "The download produced more data than allowed.") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = (try? stderr.fileHandleForReading.readToEnd()).map { String(decoding: $0.prefix(600), as: UTF8.self) } ?? ""
            throw Failure(description: message.isEmpty ? "The download failed." : message.replacingOccurrences(of: "hectord: ", with: ""))
        }
        return collector.data
    }

    /// A fresh folder only the child's user can use: created by root with mode 0700, then given
    /// to `nobody`. Under /private/var/tmp, never a path a user chooses.
    private static func privateFolder() throws -> String {
        var template = Array("/private/var/tmp/hectord-fetch.XXXXXX".utf8CString)
        guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw Failure(description: "Cannot create a temporary folder.")
        }
        let path = String(cString: created)
        if geteuid() == 0 {
            guard chown(path, nobodyUser, nobodyGroup) == 0 else {
                rmdir(path)
                throw Failure(description: "Cannot prepare a temporary folder.")
            }
        }
        return path
    }
}

/// Standard output of a child, capped.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()
    private var exceeded = false

    init(limit: Int) { self.limit = limit }

    /// `false` once the limit is passed; the data is then dropped.
    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard !exceeded else { return false }
            if buffer.count + chunk.count > limit {
                exceeded = true
                buffer = Data()
                return false
            }
            buffer.append(chunk)
            return true
        }
    }

    var data: Data { lock.withLock { buffer } }
    var overflowed: Bool { lock.withLock { exceeded } }
}
