import Foundation

/// Downloads the monthly DB-IP "IP to Country Lite" database.
///
/// DB-IP publishes `dbip-country-lite-YYYY-MM.csv.gz` at the start of each month; early in a month
/// the new file may not exist yet, so the previous month is tried as well.
public enum GeoIPUpdater {
    public static let attribution = "IP geolocation by DB-IP (https://db-ip.com), CC BY 4.0"

    /// Where the decompressed CSV is stored for the current user.
    public static var defaultDatabaseURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Netbite", directoryHint: .isDirectory)
            .appending(path: "dbip-country-lite.csv")
    }

    public static func candidateURLs(now: Date = Date()) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return [0, -1].compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: offset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month], from: date)
            let name = String(format: "dbip-country-lite-%04d-%02d.csv.gz", parts.year!, parts.month!)
            return URL(string: "https://download.db-ip.com/free/\(name)")
        }
    }

    public enum UpdateError: Error, CustomStringConvertible {
        case notFound([URL])
        case decompressionFailed(Int32)
        case implausible(ranges: Int, countries: Int)

        public var description: String {
            switch self {
            case .notFound(let urls): "No DB-IP file found at: \(urls.map(\.absoluteString).joined(separator: ", "))"
            case .decompressionFailed(let status): "gunzip failed with status \(status)."
            case .implausible(let ranges, let countries):
                "The downloaded database looks wrong (\(ranges) ranges, \(countries) countries); it was not installed."
            }
        }
    }

    /// The real database has about 700,000 ranges and 250 countries. Anything far smaller is
    /// truncated or forged, and installing it could block the wrong networks.
    static let minimumRanges = 100_000
    static let minimumCountries = 200

    /// Refuses any redirect that leaves HTTPS, so the file cannot be swapped on the way.
    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme == "https" ? request : nil
        }
    }

    /// Downloads, decompresses, validates, then atomically replaces `destination`.
    /// Returns the URL the file came from.
    @discardableResult
    public static func update(to destination: URL = defaultDatabaseURL) async throws -> URL {
        let candidates = candidateURLs()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: HTTPSOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        for source in candidates {
            let (download, response) = try await session.download(from: source)
            defer { try? FileManager.default.removeItem(at: download) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else { continue }

            let gz = download.deletingLastPathComponent().appending(path: "netbite-\(UUID().uuidString).csv.gz")
            try FileManager.default.moveItem(at: download, to: gz)
            let csv = gz.deletingPathExtension()
            defer { try? FileManager.default.removeItem(at: csv) }

            let gunzip = Process()
            gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            gunzip.arguments = ["-f", gz.path]
            try gunzip.run()
            gunzip.waitUntilExit()
            guard gunzip.terminationStatus == 0 else { throw UpdateError.decompressionFailed(gunzip.terminationStatus) }

            // Refuse to install a file we cannot read or that does not look like the real database.
            let database = try GeoIPDatabase(contentsOf: csv)
            guard database.rangeCount >= minimumRanges, database.countries.count >= minimumCountries else {
                throw UpdateError.implausible(ranges: database.rangeCount, countries: database.countries.count)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: csv)
            } else {
                try FileManager.default.moveItem(at: csv, to: destination)
            }
            return source
        }
        throw UpdateError.notFound(candidates)
    }
}
