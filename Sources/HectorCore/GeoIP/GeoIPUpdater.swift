import Foundation

/// Downloads the monthly DB-IP "IP to Country Lite" database.
///
/// DB-IP publishes `dbip-country-lite-YYYY-MM.csv.gz` at the start of each month; early in a month
/// the new file may not exist yet, so the previous month is tried as well. The download itself
/// (HTTPS only, time and size limits, gunzip) is shared with `ASNUpdater`, see `DBIPDownload`.
public enum GeoIPUpdater {
    public static let attribution = "IP geolocation by DB-IP (https://db-ip.com), CC BY 4.0"

    /// Where the decompressed CSV is stored for the current user.
    public static var defaultDatabaseURL: URL {
        LegacyMigration.userDataDirectory.appending(path: "dbip-country-lite.csv")
    }

    public static func candidateURLs(now: Date = Date()) -> [URL] {
        DBIPDownload.candidateURLs(prefix: "dbip-country-lite", now: now)
    }

    public enum UpdateError: Error, CustomStringConvertible {
        case notFound([URL])
        case decompressionFailed(Int32)
        case implausible(ranges: Int, countries: Int)
        /// The file is larger than any real DB-IP file (compressed or decompressed).
        case tooLarge(bytes: Int, limit: Int)

        public var description: String {
            switch self {
            case .notFound(let urls): "No DB-IP file found at: \(urls.map(\.absoluteString).joined(separator: ", "))"
            case .decompressionFailed(let status): "gunzip failed with status \(status)."
            case .implausible(let ranges, let countries):
                "The downloaded database looks wrong (\(ranges) ranges, \(countries) countries); it was not installed."
            case .tooLarge(let bytes, let limit):
                "The downloaded file is too large (over \(limit / 1_048_576) MB, got \(bytes / 1_048_576) MB); it was not installed."
            }
        }
    }

    /// The real database has about 700,000 ranges and 250 countries. Anything far smaller is
    /// truncated or forged, and installing it could block the wrong networks.
    static let minimumRanges = 100_000
    static let minimumCountries = 200

    /// Downloads, decompresses, validates, then atomically replaces `destination`.
    /// Returns the URL the file came from.
    @discardableResult
    public static func update(to destination: URL = defaultDatabaseURL) async throws -> URL {
        try await DBIPDownload.install(from: candidateURLs(), to: destination) { csv in
            // Parsed without the cache: it would be written next to this temporary file.
            let database = try GeoIPDatabase(csv: Data(contentsOf: csv, options: .mappedIfSafe))
            guard database.rangeCount >= minimumRanges, database.countries.count >= minimumCountries else {
                throw UpdateError.implausible(ranges: database.rangeCount, countries: database.countries.count)
            }
        }
    }
}
