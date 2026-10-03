import Foundation

/// Country lookups backed by the DB-IP "IP to Country Lite" CSV (CC BY 4.0, https://db-ip.com).
///
/// Each CSV line is `first_ip,last_ip,country_code`, IPv4 and IPv6 mixed.
/// The whole table lives in memory as sorted ranges (a few MB) and lookups are binary searches.
public final class GeoIPDatabase: Sendable {
    struct Range<T: FixedWidthInteger & Sendable>: Sendable {
        let lower: T
        let upper: T
        let country: UInt16
    }

    private let v4: [Range<UInt32>]
    private let v6: [Range<UInt128>]

    public enum LoadError: Error, CustomStringConvertible {
        case empty
        case malformedLine(Int)

        public var description: String {
            switch self {
            case .empty: "The GeoIP file contains no usable range."
            case .malformedLine(let n): "Malformed GeoIP line \(n)."
            }
        }
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(csv: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Parses DB-IP CSV data. Lines that are blank or carry no real country (`ZZ`) are skipped.
    public init(csv data: Data) throws {
        var v4: [Range<UInt32>] = []
        var v6: [Range<UInt128>] = []
        var lineNumber = 0

        for line in data.split(separator: UInt8(ascii: "\n")) {
            lineNumber += 1
            let fields = line.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
                .map { Self.field($0) }
            if fields.count == 1 && fields[0].isEmpty { continue }
            guard fields.count >= 3,
                  let lower = IPAddress(fields[0]),
                  let upper = IPAddress(fields[1]) else {
                throw LoadError.malformedLine(lineNumber)
            }
            guard let country = Self.pack(fields[2].uppercased()), country != Self.pack("ZZ") else { continue }
            switch (lower, upper) {
            case (.v4(let lo), .v4(let hi)) where lo <= hi:
                v4.append(Range(lower: lo, upper: hi, country: country))
            case (.v6(let lo), .v6(let hi)) where lo <= hi:
                v6.append(Range(lower: lo, upper: hi, country: country))
            default:
                throw LoadError.malformedLine(lineNumber)
            }
        }
        guard !v4.isEmpty || !v6.isEmpty else { throw LoadError.empty }
        self.v4 = v4.sorted { $0.lower < $1.lower }
        self.v6 = v6.sorted { $0.lower < $1.lower }
    }

    /// Number of ranges loaded (IPv4 + IPv6).
    public var rangeCount: Int { v4.count + v6.count }

    /// Every ISO 3166-1 alpha-2 code present in the database.
    public var countries: Set<String> {
        Set((v4.map(\.country) + v6.map(\.country)).map(Self.unpack))
    }

    /// The ISO country code an address belongs to, or `nil` (private ranges, unknown space).
    public func country(for address: IPAddress) -> String? {
        switch address {
        case .v4(let value): Self.find(value, in: v4).map(Self.unpack)
        case .v6(let value): Self.find(value, in: v6).map(Self.unpack)
        }
    }

    /// The networks covering every range of `country`, adjacent ranges merged first.
    public func networks(for country: String) -> [CIDR] {
        guard let code = Self.pack(country.uppercased()) else { return [] }
        let merged4 = Self.merge(v4.filter { $0.country == code })
        let merged6 = Self.merge(v6.filter { $0.country == code })
        return merged4.flatMap { CIDR.covering(from: .v4($0.lower), to: .v4($0.upper)) }
            + merged6.flatMap { CIDR.covering(from: .v6($0.lower), to: .v6($0.upper)) }
    }

    // MARK: - Helpers

    private static func find<T>(_ value: T, in ranges: [Range<T>]) -> UInt16? {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = ranges[mid]
            if value < range.lower {
                high = mid - 1
            } else if value > range.upper {
                low = mid + 1
            } else {
                return range.country
            }
        }
        return nil
    }

    private static func merge<T>(_ ranges: [Range<T>]) -> [Range<T>] {
        var merged: [Range<T>] = []
        for range in ranges {
            if let last = merged.last, last.upper != T.max, last.upper + 1 >= range.lower {
                merged[merged.count - 1] = Range(lower: last.lower, upper: max(last.upper, range.upper), country: last.country)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func field(_ bytes: Data.SubSequence) -> String {
        var s = String(decoding: bytes, as: UTF8.self)
        s.removeAll { $0 == "\"" || $0 == "\r" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func pack(_ code: String) -> UInt16? {
        let bytes = Array(code.utf8)
        guard bytes.count == 2, bytes.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private static func unpack(_ code: UInt16) -> String {
        String(decoding: [UInt8(code >> 8), UInt8(code & 0xFF)], as: UTF8.self)
    }
}
