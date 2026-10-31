import Foundation

/// Download plumbing shared by the DB-IP databases (country and ASN).
///
/// DB-IP publishes `<prefix>-YYYY-MM.csv.gz` at the start of each month under
/// `https://download.db-ip.com/free/`. A download is only ever started by the user (or by the
/// helper when a country is blocked): HTTPS only, redirects included, bounded in time and size,
/// checked by the caller before it replaces the installed file.
enum DBIPDownload {
    /// A compressed file larger than this is refused. The real files are a few tens of MB.
    static let maximumCompressedBytes = 150 * 1024 * 1024
    /// Decompression stops past this size, so a gzip bomb cannot fill the disk.
    static let maximumDecompressedBytes = 600 * 1024 * 1024

    /// This month's file, then last month's: early in a month the new file may not exist yet.
    static func candidateURLs(prefix: String, now: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return [0, -1].compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: offset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { return nil }
            let name = prefix + String(format: "-%04d-%02d.csv.gz", year, month)
            return URL(string: "https://download.db-ip.com/free/\(name)")
        }
    }

    /// Refuses any redirect that leaves HTTPS, so the file cannot be swapped on the way.
    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme == "https" ? request : nil
        }
    }

    /// Downloads the first candidate that exists, decompresses it, lets `validate` refuse it, then
    /// atomically replaces `destination`. Returns the URL the file came from.
    static func install(from candidates: [URL], to destination: URL, validate: (URL) throws -> Void) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: HTTPSOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        for source in candidates {
            // Not `session.download`: it writes to the system's per-user temporary folder, which
            // the helper's sandbox refuses ("Operation not permitted"). This stays in TMPDIR.
            let (bytes, response) = try await session.bytes(from: source)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
                bytes.task.cancel()
                continue
            }

            let gz = temporaryFolder.appending(path: "hector-\(UUID().uuidString).csv.gz")
            defer { try? FileManager.default.removeItem(at: gz) }
            do {
                try await save(bytes, to: gz)
            } catch {
                bytes.task.cancel()
                throw error
            }
            let csv = gz.deletingPathExtension()
            defer { try? FileManager.default.removeItem(at: csv) }

            try gunzip(gz, to: csv, maximumBytes: maximumDecompressedBytes)
            // Refuse to install a file we cannot read or that does not look like the real database.
            try validate(csv)

            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: csv)
            } else {
                try FileManager.default.moveItem(at: csv, to: destination)
            }
            return source
        }
        throw GeoIPUpdater.UpdateError.notFound(candidates)
    }

    /// `TMPDIR` when set: the helper's download child sets it to its private folder, the only
    /// place the sandbox lets it write, and `NSTemporaryDirectory()` does not follow it.
    static var temporaryFolder: URL {
        let path = getenv("TMPDIR").map { String(cString: $0) } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Creates a file with `open`: `FileManager.createFile` goes through the per-user temporary
    /// folder too, and fails under the helper's sandbox.
    private static func newFile(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Writes a download to `destination`, failing past `maximumCompressedBytes`.
    private static func save(_ bytes: URLSession.AsyncBytes, to destination: URL) async throws {
        let output = try newFile(at: destination)
        defer { try? output.close() }
        var buffer = Data(capacity: 1 << 20)
        var written = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 20 {
                written += buffer.count
                guard written <= maximumCompressedBytes else {
                    throw GeoIPUpdater.UpdateError.tooLarge(bytes: written, limit: maximumCompressedBytes)
                }
                try output.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try output.write(contentsOf: buffer)
    }

    /// Decompresses `source` into `destination` with `/usr/bin/gunzip -c`, stopping (and failing)
    /// once more than `maximumBytes` have come out.
    static func gunzip(_ source: URL, to destination: URL, maximumBytes: Int) throws {
        let output = try newFile(at: destination)
        defer { try? output.close() }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let reader = pipe.fileHandleForReading
        var written = 0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            written += chunk.count
            if written > maximumBytes {
                process.terminate()
                process.waitUntilExit()
                throw GeoIPUpdater.UpdateError.tooLarge(bytes: written, limit: maximumBytes)
            }
            try output.write(contentsOf: chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GeoIPUpdater.UpdateError.decompressionFailed(process.terminationStatus)
        }
    }
}
