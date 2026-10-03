import Foundation

/// The autonomous system (the network) an address belongs to: "AS15169 Google LLC".
public struct NetworkOwner: Hashable, Sendable, Codable {
    /// The autonomous system number.
    public let number: UInt32
    /// The organization that operates it, as published in the database; may be empty.
    public let name: String

    public init(number: UInt32, name: String) {
        self.number = number
        self.name = name
    }

    /// "AS15169".
    public var asLabel: String { "AS\(number)" }

    /// The organization name, or the AS number when the name is unknown.
    public var displayName: String { name.isEmpty ? asLabel : name }

    /// "AS15169 Google LLC".
    public var label: String { name.isEmpty ? asLabel : "\(asLabel) \(name)" }

    /// Whether a search query matches: "15169", "as15169", "google". `query` must be lowercased.
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return label.lowercased().contains(query) || String(number) == query
    }
}

/// Network names backed by the DB-IP "IP to ASN Lite" CSV (CC BY 4.0, https://db-ip.com).
///
/// Each CSV line is `first_ip,last_ip,as_number,as_organization`, IPv4 and IPv6 mixed, the
/// organization quoted when it contains a comma (`"Cloudflare, Inc."`).
///
/// The file is larger than the country one, so the table is kept compact:
/// - an IPv4 range is 12 bytes (two `UInt32` bounds and an owner index), an IPv6 range 48;
/// - adjacent ranges of the same network are merged while loading;
/// - each organization name is stored once, in one shared UTF-8 buffer, not as one `String`
///   per range; a `NetworkOwner` is only built for the address being looked up.
/// Lookups are binary searches.
public final class ASNDatabase: Sendable {
    struct Range<T: FixedWidthInteger & Sendable & BitwiseCopyable>: Sendable, BitwiseCopyable {
        let lower: T
        var upper: T
        let owner: UInt32
    }

    // Tables of records, parsed or mapped from the cache next to the CSV (see `RecordCache`).
    private let v4: RecordTable<Range<UInt32>>
    private let v6: RecordTable<Range<UInt128>>
    /// AS number of each owner index.
    private let numbers: RecordTable<UInt32>
    /// Name of owner `i` is `nameBytes[nameOffsets[i]..<nameOffsets[i + 1]]`.
    private let nameOffsets: RecordTable<UInt32>
    private let nameBytes: RecordTable<UInt8>

    static let cacheLayout = RecordCache.layout([MemoryLayout<Range<UInt32>>.stride, MemoryLayout<Range<UInt128>>.stride], version: 1)

    /// Organization names longer than this are cut: they are labels, not documents.
    static let maximumNameLength = 120

    public enum LoadError: Error, CustomStringConvertible {
        case empty
        case malformedLine(Int)

        public var description: String {
            switch self {
            case .empty: "The ASN file contains no usable range."
            case .malformedLine(let n): "Malformed ASN line \(n)."
            }
        }
    }

    public convenience init(contentsOf url: URL) throws {
        let stamp = RecordCache.Stamp(source: url, layout: Self.cacheLayout)
        let cacheURL = RecordCache.url(for: url)
        if let stamp, let s = RecordCache.read(from: cacheURL, stamp: stamp, sections: 5),
           let v4 = RecordTable<Range<UInt32>>(data: s[0].data, offset: s[0].offset, count: s[0].count),
           let v6 = RecordTable<Range<UInt128>>(data: s[1].data, offset: s[1].offset, count: s[1].count),
           let numbers = RecordTable<UInt32>(data: s[2].data, offset: s[2].offset, count: s[2].count),
           let offsets = RecordTable<UInt32>(data: s[3].data, offset: s[3].offset, count: s[3].count),
           let names = RecordTable<UInt8>(data: s[4].data, offset: s[4].offset, count: s[4].count),
           Self.isConsistent(v4: v4, v6: v6, numbers: numbers, offsets: offsets, names: names) {
            self.init(v4: v4, v6: v6, numbers: numbers, nameOffsets: offsets, nameBytes: names)
            return
        }
        try self.init(csv: Data(contentsOf: url, options: .mappedIfSafe))
        if let stamp {
            RecordCache.write([(v4.data, v4.count), (v6.data, v6.count), (numbers.data, numbers.count),
                               (nameOffsets.data, nameOffsets.count), (nameBytes.data, nameBytes.count)],
                              stamp: stamp, to: cacheURL)
        }
    }

    private init(v4: RecordTable<Range<UInt32>>, v6: RecordTable<Range<UInt128>>, numbers: RecordTable<UInt32>,
                 nameOffsets: RecordTable<UInt32>, nameBytes: RecordTable<UInt8>) {
        self.v4 = v4
        self.v6 = v6
        self.numbers = numbers
        self.nameOffsets = nameOffsets
        self.nameBytes = nameBytes
    }

    /// Everything a lookup relies on, checked once when a cache is mapped: ordered ranges, owner
    /// indices in bounds, name offsets increasing within the name bytes.
    private static func isConsistent(v4: RecordTable<Range<UInt32>>, v6: RecordTable<Range<UInt128>>,
                                     numbers: RecordTable<UInt32>, offsets: RecordTable<UInt32>,
                                     names: RecordTable<UInt8>) -> Bool {
        guard v4.count + v6.count > 0, offsets.count == numbers.count + 1 else { return false }
        let owners = UInt32(numbers.count)
        func ordered<T>(_ table: RecordTable<Range<T>>) -> Bool {
            table.withBuffer { ranges in
                var previous: T?
                for range in ranges {
                    guard range.lower <= range.upper, range.owner < owners,
                          previous.map({ $0 < range.lower }) ?? true else { return false }
                    previous = range.upper
                }
                return true
            }
        }
        let offsetsValid = offsets.withBuffer { values in
            guard values.first == 0 else { return false }
            var previous: UInt32 = 0
            for value in values {
                guard value >= previous, Int(value) <= names.count else { return false }
                previous = value
            }
            return true
        }
        return offsetsValid && ordered(v4) && ordered(v6)
    }

    /// Parses DB-IP ASN CSV data. Blank lines, a header line and lines without an AS number
    /// (`0` or empty) are skipped; a line whose addresses cannot be read is an error.
    public init(csv data: Data) throws {
        var builder = Builder()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            var lineNumber = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count && bytes[end] != UInt8(ascii: "\n") { end += 1 }
                lineNumber += 1
                try builder.add(line: UnsafeBufferPointer(rebasing: bytes[start..<end]), number: lineNumber)
                start = end + 1
            }
        }
        guard !builder.v4.isEmpty || !builder.v6.isEmpty else { throw LoadError.empty }
        builder.finish()
        v4 = RecordTable(builder.v4)
        v6 = RecordTable(builder.v6)
        numbers = RecordTable(builder.numbers)
        nameOffsets = RecordTable(builder.nameOffsets)
        nameBytes = RecordTable(builder.nameBytes)
    }

    /// Number of ranges kept after merging (IPv4 + IPv6).
    public var rangeCount: Int { v4.count + v6.count }

    /// Number of distinct autonomous systems.
    public var networkCount: Int { numbers.count }

    /// The network an address belongs to, or `nil` (private ranges, unannounced space).
    public func owner(for address: IPAddress) -> NetworkOwner? {
        let index: UInt32?
        switch address.normalized {
        case .v4(let value): index = Self.find(value, in: v4)
        case .v6(let value): index = Self.find(value, in: v6)
        }
        return index.flatMap { owner(at: $0) }
    }

    private func owner(at index: UInt32) -> NetworkOwner? {
        let i = Int(index)
        guard i + 1 < nameOffsets.count else { return nil }
        let (lower, upper) = nameOffsets.withBuffer { (Int($0[i]), Int($0[i + 1])) }
        guard lower <= upper, upper <= nameBytes.count else { return nil }
        let name = nameBytes.withBuffer { String(decoding: UnsafeBufferPointer(rebasing: $0[lower..<upper]), as: UTF8.self) }
        // Cleaned again: the cache is a file like any other.
        return NetworkOwner(number: numbers.withBuffer { $0[i] }, name: Builder.clean(name))
    }

    private static func find<T>(_ value: T, in table: RecordTable<Range<T>>) -> UInt32? {
        table.withBuffer { find(value, in: $0) }
    }

    private static func find<T>(_ value: T, in ranges: UnsafeBufferPointer<Range<T>>) -> UInt32? {
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
                return range.owner
            }
        }
        return nil
    }

    // MARK: - Loading

    /// Accumulates ranges and interns organization names while the file is read.
    struct Builder {
        var v4: [Range<UInt32>] = []
        var v6: [Range<UInt128>] = []
        var numbers: [UInt32] = []
        var nameOffsets: [UInt32] = [0]
        var nameBytes: [UInt8] = []
        private var ownerIndex: [UInt32: UInt32] = [:]
        private var v4Sorted = true
        private var v6Sorted = true

        mutating func add(line: UnsafeBufferPointer<UInt8>, number lineNumber: Int) throws {
            let fields = CSVLine.fields(line)
            if fields.count == 1 && fields[0].isEmpty { return }
            guard fields.count >= 3, let lower = IPAddress(fields[0]), let upper = IPAddress(fields[1]) else {
                // Tolerate a header line such as `start_ip,end_ip,as_number,as_organization`.
                if lineNumber == 1 { return }
                throw ASNDatabase.LoadError.malformedLine(lineNumber)
            }
            guard let asn = Self.asNumber(fields[2]), asn != 0 else { return }
            let name = fields.count >= 4 ? Self.clean(fields[3]) : ""
            let owner = intern(asn, name: name)
            switch (lower, upper) {
            case (.v4(let lo), .v4(let hi)) where lo <= hi:
                Self.append(Range(lower: lo, upper: hi, owner: owner), to: &v4, sorted: &v4Sorted)
            case (.v6(let lo), .v6(let hi)) where lo <= hi:
                Self.append(Range(lower: lo, upper: hi, owner: owner), to: &v6, sorted: &v6Sorted)
            default:
                throw ASNDatabase.LoadError.malformedLine(lineNumber)
            }
        }

        /// Sorts the tables when the file was not in order (DB-IP's files are), then drops the spare
        /// capacity arrays keep while growing (up to half of their size).
        mutating func finish() {
            if !v4Sorted { v4 = Self.mergedAfterSorting(v4) }
            if !v6Sorted { v6 = Self.mergedAfterSorting(v6) }
            v4 = v4.withUnsafeBufferPointer { Array($0) }
            v6 = v6.withUnsafeBufferPointer { Array($0) }
            numbers = numbers.withUnsafeBufferPointer { Array($0) }
            nameOffsets = nameOffsets.withUnsafeBufferPointer { Array($0) }
            nameBytes = nameBytes.withUnsafeBufferPointer { Array($0) }
            ownerIndex = [:]
        }

        private mutating func intern(_ asn: UInt32, name: String) -> UInt32 {
            if let index = ownerIndex[asn] { return index }
            let index = UInt32(numbers.count)
            numbers.append(asn)
            nameBytes.append(contentsOf: name.utf8)
            nameOffsets.append(UInt32(nameBytes.count))
            ownerIndex[asn] = index
            return index
        }

        /// Appends, merging with the previous range when it is the same network and adjacent.
        private static func append<T>(_ range: Range<T>, to ranges: inout [Range<T>], sorted: inout Bool) {
            guard let last = ranges.last else {
                ranges.append(range)
                return
            }
            if range.lower <= last.upper { sorted = false }
            if sorted, last.owner == range.owner, last.upper != T.max, last.upper + 1 == range.lower {
                ranges[ranges.count - 1].upper = range.upper
            } else {
                ranges.append(range)
            }
        }

        private static func mergedAfterSorting<T>(_ ranges: [Range<T>]) -> [Range<T>] {
            var merged: [Range<T>] = []
            merged.reserveCapacity(ranges.count)
            for range in ranges.sorted(by: { $0.lower < $1.lower }) {
                // Overlapping ranges (DB-IP has none) are kept as they are; only adjacent ones merge.
                var mergeable = true
                append(range, to: &merged, sorted: &mergeable)
            }
            return merged
        }

        /// "15169" or "AS15169".
        static func asNumber(_ field: String) -> UInt32? {
            var digits = Substring(field)
            if digits.uppercased().hasPrefix("AS") { digits = digits.dropFirst(2) }
            return UInt32(digits)
        }

        /// Removes control and invisible formatting characters (terminal escapes, bidi overrides)
        /// from a name that came from a downloaded file, and caps its length.
        static func clean(_ name: String) -> String {
            var scalars = String.UnicodeScalarView()
            for scalar in name.unicodeScalars {
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .surrogate, .privateUse:
                    continue
                default:
                    scalars.append(scalar)
                }
            }
            let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
            guard cleaned.count > ASNDatabase.maximumNameLength else { return cleaned }
            return String(cleaned.prefix(ASNDatabase.maximumNameLength))
        }
    }
}

/// Splits one CSV line into fields: commas separate fields, double quotes protect commas, and
/// `""` inside quotes is a literal quote. Carriage returns are dropped; fields are trimmed.
enum CSVLine {
    static func fields(_ line: UnsafeBufferPointer<UInt8>) -> [String] {
        var fields: [String] = []
        var current: [UInt8] = []
        var quoted = false
        var index = 0
        while index < line.count {
            let byte = line[index]
            index += 1
            if quoted {
                if byte == UInt8(ascii: "\"") {
                    if index < line.count && line[index] == UInt8(ascii: "\"") {
                        current.append(byte)
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(byte)
                }
            } else if byte == UInt8(ascii: "\"") {
                quoted = true
            } else if byte == UInt8(ascii: ",") {
                fields.append(finish(current))
                current.removeAll(keepingCapacity: true)
            } else if byte != UInt8(ascii: "\r") {
                current.append(byte)
            }
        }
        fields.append(finish(current))
        return fields
    }

    private static func finish(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
