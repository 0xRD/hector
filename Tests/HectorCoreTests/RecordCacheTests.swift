import Foundation
import Testing
@testable import HectorCore

@Suite struct RecordCacheTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hector-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func addresses(_ list: [String]) -> [IPAddress] { list.compactMap { IPAddress($0) } }

    @Test func countryCacheGivesTheSameAnswers() throws {
        let dir = try directory()
        let csv = dir.appending(path: "countries.csv")
        try Data(GeoIPDatabaseTests.csv.utf8).write(to: csv)
        let parsed = try GeoIPDatabase(contentsOf: csv)
        #expect(FileManager.default.fileExists(atPath: RecordCache.url(for: csv).path))
        let mapped = try GeoIPDatabase(contentsOf: csv)
        for address in addresses(["1.0.0.1", "1.0.2.9", "5.8.1.1", "10.1.1.1", "2001:db8::1", "2001:db9::1", "8.8.8.8"]) {
            #expect(parsed.country(for: address) == mapped.country(for: address))
        }
        #expect(mapped.rangeCount == parsed.rangeCount)
        #expect(mapped.countries == parsed.countries)
        #expect(mapped.networks(for: "CN") == parsed.networks(for: "CN"))
    }

    @Test func networkCacheGivesTheSameAnswers() throws {
        let dir = try directory()
        let csv = dir.appending(path: "asn.csv")
        try Data(ASNDatabaseTests.csv.utf8).write(to: csv)
        let parsed = try ASNDatabase(contentsOf: csv)
        let mapped = try ASNDatabase(contentsOf: csv)
        for address in addresses(["192.0.2.1", "192.0.2.200", "198.51.100.7", "203.0.113.70", "2001:db8::5", "8.8.8.8"]) {
            #expect(parsed.owner(for: address) == mapped.owner(for: address))
        }
        #expect(mapped.networkCount == parsed.networkCount)
    }

    @Test func aChangedSourceRebuildsTheCache() throws {
        let dir = try directory()
        let csv = dir.appending(path: "countries.csv")
        try Data(GeoIPDatabaseTests.csv.utf8).write(to: csv)
        _ = try GeoIPDatabase(contentsOf: csv)
        try Data("9.9.9.0,9.9.9.255,CH\n".utf8).write(to: csv)
        let updated = try GeoIPDatabase(contentsOf: csv)
        #expect(updated.country(for: IPAddress("9.9.9.9")!) == "CH")
        #expect(updated.country(for: IPAddress("1.0.0.1")!) == nil)
    }

    @Test func damagedCachesAreIgnored() throws {
        let dir = try directory()
        let csv = dir.appending(path: "asn.csv")
        try Data(ASNDatabaseTests.csv.utf8).write(to: csv)
        _ = try ASNDatabase(contentsOf: csv)
        let cache = RecordCache.url(for: csv)
        let good = try Data(contentsOf: cache)
        let probe = IPAddress("198.51.100.7")!
        // Truncated, flipped bytes everywhere, and an offset pointing past the end: each must be
        // rejected (rebuilt from the CSV), never read out of bounds or answered wrongly.
        var variants: [Data] = [good.prefix(good.count / 2), good.prefix(10)]
        for position in stride(from: 40, to: good.count, by: max(1, good.count / 97)) {
            var copy = good
            copy[position] ^= 0xFF
            variants.append(copy)
        }
        var badOffset = good
        badOffset.replaceSubrange((good.count - 16)..<(good.count - 8), with: withUnsafeBytes(of: UInt64(1 << 40)) { Data($0) })
        variants.append(badOffset)
        for variant in variants {
            try variant.write(to: cache)
            // Keep the stamp valid so the damaged content itself is what gets checked.
            let db = try ASNDatabase(contentsOf: csv)
            let owner = db.owner(for: probe)
            #expect(owner == nil || owner?.number == 64497)
        }
    }

    @Test func tablesRejectViewsOutsideTheirData() {
        let data = Data(count: 64)
        #expect(RecordTable<UInt64>(data: data, offset: 0, count: 8) != nil)
        #expect(RecordTable<UInt64>(data: data, offset: 8, count: 8) == nil)
        #expect(RecordTable<UInt64>(data: data, offset: 4, count: 1) == nil)
        #expect(RecordTable<UInt64>(data: data, offset: 128, count: 0) == nil || RecordTable<UInt64>(data: data, offset: 128, count: 0)?.count == 0)
        #expect(RecordTable<UInt64>(data: data, offset: -8, count: 1) == nil)
    }
}
