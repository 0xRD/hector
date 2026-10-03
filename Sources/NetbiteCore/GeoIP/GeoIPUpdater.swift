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

        public var description: String {
            switch self {
            case .notFound(let urls): "No DB-IP file found at: \(urls.map(\.absoluteString).joined(separator: ", "))"
            case .decompressionFailed(let status): "gunzip failed with status \(status)."
            }
        }
    }

    /// Downloads, decompresses, validates, then atomically replaces `destination`.
    /// Returns the URL the file came from.
    @discardableResult
    public static func update(to destination: URL = defaultDatabaseURL) async throws -> URL {
        let candidates = candidateURLs()
        for source in candidates {
            let (download, response) = try await URLSession.shared.download(from: source)
            defer { try? FileManager.default.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }

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

            _ = try GeoIPDatabase(contentsOf: csv)  // Refuse to install a file we cannot read.
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
