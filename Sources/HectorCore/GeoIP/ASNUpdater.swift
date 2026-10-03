import Foundation

/// Downloads the monthly DB-IP "IP to ASN Lite" database (CC BY 4.0), the source of network names.
///
/// Same publisher, same monthly naming and same download rules as the country database
/// (`dbip-asn-lite-YYYY-MM.csv.gz`, see `DBIPDownload`). Only the user starts it, from the app
/// or with `hector geo update --asn`; the helper never needs it, since nothing is blocked by network.
public enum ASNUpdater {
    public static let attribution = "Network names by DB-IP (https://db-ip.com), CC BY 4.0"

    /// Where the decompressed CSV is stored for the current user, next to the country database.
    public static var defaultDatabaseURL: URL {
        LegacyMigration.userDataDirectory.appending(path: "dbip-asn-lite.csv")
    }

    public static func candidateURLs(now: Date = Date()) -> [URL] {
        DBIPDownload.candidateURLs(prefix: "dbip-asn-lite", now: now)
    }

    public enum UpdateError: Error, CustomStringConvertible {
        case implausible(ranges: Int, networks: Int)

        public var description: String {
            switch self {
            case .implausible(let ranges, let networks):
                "The downloaded network database looks wrong (\(ranges) ranges, \(networks) networks); it was not installed."
            }
        }
    }

    /// The real file maps hundreds of thousands of ranges to tens of thousands of networks.
    /// Names are only displayed, never used to block, so this only catches truncated files.
    static let minimumRanges = 50_000
    static let minimumNetworks = 5_000

    /// Downloads, decompresses, validates, then atomically replaces `destination`.
    /// Returns the URL the file came from.
    @discardableResult
    public static func update(to destination: URL = defaultDatabaseURL) async throws -> URL {
        try await DBIPDownload.install(from: candidateURLs(), to: destination) { csv in
            let database = try ASNDatabase(contentsOf: csv)
            guard database.rangeCount >= minimumRanges, database.networkCount >= minimumNetworks else {
                throw UpdateError.implausible(ranges: database.rangeCount, networks: database.networkCount)
            }
        }
    }
}
