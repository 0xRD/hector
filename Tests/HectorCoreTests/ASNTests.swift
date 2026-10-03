import Foundation
import Testing
@testable import HectorCore

@Suite struct ASNDatabaseTests {
    // Same shape as the DB-IP "IP to ASN Lite" CSV, documentation ranges and AS numbers only
    // (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32; AS64496–AS64511).
    static let csv = """
    192.0.2.0,192.0.2.127,64496,Example Transit LLC
    192.0.2.128,192.0.2.255,64496,Example Transit LLC
    "198.51.100.0","198.51.100.255","64497","Example Cloud, Inc."
    203.0.113.0,203.0.113.63,0,
    203.0.113.64,203.0.113.127,64498,"The ""Quoted"" Network"\r
    2001:db8::,2001:db8:ffff:ffff:ffff:ffff:ffff:ffff,64499,Example IPv6 Net

    """

    static let db = try! ASNDatabase(csv: Data(csv.utf8))

    @Test func looksUpOwners() {
        #expect(Self.db.owner(for: IPAddress("192.0.2.200")!) == NetworkOwner(number: 64496, name: "Example Transit LLC"))
        #expect(Self.db.owner(for: IPAddress("198.51.100.7")!)?.name == "Example Cloud, Inc.")
        #expect(Self.db.owner(for: IPAddress("203.0.113.100")!)?.name == "The \"Quoted\" Network")
        #expect(Self.db.owner(for: IPAddress("2001:db8::1")!)?.number == 64499)
        // IPv4-mapped IPv6 addresses are looked up as IPv4.
        #expect(Self.db.owner(for: IPAddress("::ffff:198.51.100.7")!)?.number == 64497)
    }

    @Test func skipsUnknownSpace() {
        // AS0 means "not announced".
        #expect(Self.db.owner(for: IPAddress("203.0.113.10")!) == nil)
        #expect(Self.db.owner(for: IPAddress("10.0.0.1")!) == nil)
        #expect(Self.db.owner(for: IPAddress("2001:db9::1")!) == nil)
    }

    @Test func mergesAdjacentRangesAndInternsNames() {
        // The two halves of 192.0.2.0/24 belong to the same network: one range.
        #expect(Self.db.rangeCount == 4)
        #expect(Self.db.networkCount == 4)
    }

    @Test func formatsLabels() {
        let owner = NetworkOwner(number: 15169, name: "Google LLC")
        #expect(owner.label == "AS15169 Google LLC")
        #expect(owner.displayName == "Google LLC")
        #expect(NetworkOwner(number: 64500, name: "").label == "AS64500")
        #expect(NetworkOwner(number: 64500, name: "").displayName == "AS64500")
    }

    @Test func matchesSearchQueries() {
        let owner = NetworkOwner(number: 15169, name: "Google LLC")
        #expect(owner.matches("google"))
        #expect(owner.matches("as15169"))
        #expect(owner.matches("15169"))
        #expect(!owner.matches("cloudflare"))
    }

    @Test func toleratesHeaderAndUnsortedInput() throws {
        let csv = """
        start_ip,end_ip,as_number,as_organization
        198.51.100.0,198.51.100.255,AS64497,Second
        192.0.2.0,192.0.2.255,64496,First
        """
        let db = try ASNDatabase(csv: Data(csv.utf8))
        #expect(db.owner(for: IPAddress("192.0.2.1")!)?.name == "First")
        #expect(db.owner(for: IPAddress("198.51.100.1")!)?.name == "Second")
        #expect(db.rangeCount == 2)
    }

    @Test func removesControlCharactersFromNames() throws {
        // A forged file must not be able to send terminal escapes or reorder text with bidi controls.
        let csv = "192.0.2.0,192.0.2.255,64496,Evil\u{1B}[31m Corp\u{202E}\n"
        let db = try ASNDatabase(csv: Data(csv.utf8))
        #expect(db.owner(for: IPAddress("192.0.2.1")!)?.name == "Evil[31m Corp")
        let long = String(repeating: "x", count: 500)
        #expect(ASNDatabase.Builder.clean(long).count == ASNDatabase.maximumNameLength)
    }

    @Test func rejectsMalformedFiles() {
        #expect(throws: ASNDatabase.LoadError.self) { try ASNDatabase(csv: Data("192.0.2.0,192.0.2.255,64496,A\n1.0.0.0,oops,1,B\n".utf8)) }
        #expect(throws: ASNDatabase.LoadError.self) { try ASNDatabase(csv: Data("\n".utf8)) }
        // IPv4 start with an IPv6 end.
        #expect(throws: ASNDatabase.LoadError.self) { try ASNDatabase(csv: Data("192.0.2.0,192.0.2.255,1,A\n192.0.2.0,2001:db8::,1,A\n".utf8)) }
    }

    @Test func buildsMonthlyDownloadURLs() {
        let date = ISO8601DateFormatter().date(from: "2026-01-03T12:00:00Z")!
        #expect(ASNUpdater.candidateURLs(now: date).map(\.absoluteString) == [
            "https://download.db-ip.com/free/dbip-asn-lite-2026-01.csv.gz",
            "https://download.db-ip.com/free/dbip-asn-lite-2025-12.csv.gz",
        ])
        #expect(ASNUpdater.defaultDatabaseURL.deletingLastPathComponent() == GeoIPUpdater.defaultDatabaseURL.deletingLastPathComponent())
    }
}

@Suite struct DBIPDownloadTests {
    /// Gzips `text` into a temporary file with the system's gzip.
    private func gzipped(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hector-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = directory.appending(path: "data.csv")
        try Data(text.utf8).write(to: plain)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-f", plain.path]
        try gzip.run()
        gzip.waitUntilExit()
        return directory.appending(path: "data.csv.gz")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/gzip")
                   && FileManager.default.isExecutableFile(atPath: "/usr/bin/gunzip")))
    func decompressesWithinTheLimit() throws {
        let text = String(repeating: "192.0.2.0,192.0.2.255,64496,Example\n", count: 1000)
        let gz = try gzipped(text)
        defer { try? FileManager.default.removeItem(at: gz.deletingLastPathComponent()) }
        let out = gz.deletingLastPathComponent().appending(path: "out.csv")
        try DBIPDownload.gunzip(gz, to: out, maximumBytes: 1_000_000)
        #expect(try String(contentsOf: out, encoding: .utf8) == text)

        // Highly compressible input that grows past the limit is refused.
        #expect(throws: GeoIPUpdater.UpdateError.self) {
            try DBIPDownload.gunzip(gz, to: out, maximumBytes: 1_000)
        }
    }
}
