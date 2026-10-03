import Foundation
import Testing
@testable import NetbiteCore

@Suite struct GeoIPDatabaseTests {
    // Same shape as the DB-IP Lite CSV, documentation ranges only.
    static let csv = """
    1.0.0.0,1.0.0.255,AU
    "1.0.1.0","1.0.3.255","CN"
    1.0.4.0,1.0.7.255,CN
    5.8.0.0,5.8.7.255,RU
    10.0.0.0,10.255.255.255,ZZ
    2001:db8::,2001:db8:ffff:ffff:ffff:ffff:ffff:ffff,CN
    2001:db9::,2001:db9::ffff,de

    """

    static let db = try! GeoIPDatabase(csv: Data(csv.utf8))

    @Test func looksUpCountries() {
        #expect(Self.db.country(for: IPAddress("1.0.0.42")!) == "AU")
        #expect(Self.db.country(for: IPAddress("1.0.2.1")!) == "CN")
        #expect(Self.db.country(for: IPAddress("5.8.3.3")!) == "RU")
        #expect(Self.db.country(for: IPAddress("2001:db8::1")!) == "CN")
        #expect(Self.db.country(for: IPAddress("2001:db9::1")!) == "DE")
    }

    @Test func skipsUnknownSpace() {
        #expect(Self.db.country(for: IPAddress("10.1.1.1")!) == nil)
        #expect(Self.db.country(for: IPAddress("9.9.9.9")!) == nil)
        #expect(!Self.db.countries.contains("ZZ"))
        #expect(Self.db.rangeCount == 6)
    }

    @Test func mergesAdjacentRangesIntoNetworks() {
        // 1.0.1.0–1.0.3.255 and 1.0.4.0–1.0.7.255 are adjacent: 1.0.1.0/24, 1.0.2.0/23, 1.0.4.0/22.
        let networks = Self.db.networks(for: "cn").map(\.description)
        #expect(networks == ["1.0.1.0/24", "1.0.2.0/23", "1.0.4.0/22", "2001:db8::/32"])
        #expect(Self.db.networks(for: "FR").isEmpty)
    }

    @Test func rejectsMalformedFiles() {
        #expect(throws: GeoIPDatabase.LoadError.self) { try GeoIPDatabase(csv: Data("1.0.0.0,oops,AU\n".utf8)) }
        #expect(throws: GeoIPDatabase.LoadError.self) { try GeoIPDatabase(csv: Data("\n".utf8)) }
    }

    @Test func buildsMonthlyDownloadURLs() {
        let date = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!
        #expect(GeoIPUpdater.candidateURLs(now: date).map(\.lastPathComponent) == [
            "dbip-country-lite-2026-10.csv.gz", "dbip-country-lite-2026-09.csv.gz",
        ])
    }
}
