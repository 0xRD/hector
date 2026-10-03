import Foundation

/// A table of fixed-size records kept in a `Data`: built in memory from parsed values, or mapped
/// from a cache file without copying.
///
/// The IP databases are about a million ranges. Parsing their CSV at every launch took a second
/// and left 30 to 80 MB of dirty memory; mapped from a cache, the tables load in a few
/// milliseconds and their pages are clean, so macOS can drop and reload them as it needs.
struct RecordTable<Element: BitwiseCopyable>: @unchecked Sendable {
    let data: Data
    let offset: Int
    let count: Int

    init(_ elements: [Element]) {
        data = elements.withUnsafeBufferPointer { Data(buffer: $0) }
        offset = 0
        count = elements.count
    }

    /// A view of `count` records at `offset` in `data`; `nil` when they do not fit or are
    /// misaligned (a damaged cache).
    init?(data: Data, offset: Int, count: Int) {
        let stride = MemoryLayout<Element>.stride
        guard offset >= 0, count >= 0, offset % MemoryLayout<Element>.alignment == 0,
              count <= (data.count - min(offset, data.count)) / max(stride, 1) else { return nil }
        self.data = data
        self.offset = offset
        self.count = count
    }

    var byteCount: Int { count * MemoryLayout<Element>.stride }

    func withBuffer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { raw in
            guard count > 0, let base = raw.baseAddress else { return try body(UnsafeBufferPointer(start: nil, count: 0)) }
            return try body(UnsafeBufferPointer(start: (base + offset).assumingMemoryBound(to: Element.self), count: count))
        }
    }

    var array: [Element] { withBuffer { Array($0) } }
}

/// The cache file of a database: a header, then the tables one after the other, each aligned to
/// 16 bytes. Written next to the CSV it was built from and used only while that CSV keeps the
/// same size and modification date, by the same build layout.
enum RecordCache {
    private static let magic: UInt64 = 0x3130_4244_5254_4348 // "HCTRDB01", little-endian
    private static let headerSize = 64
    private static let maximumSections = 6

    struct Section {
        let data: Data
        let offset: Int
        let count: Int
    }

    /// What the cache must match: the source file's size and date, and the record layout.
    struct Stamp: Equatable {
        let sourceSize: UInt64
        let sourceModified: Int64
        let layout: UInt64

        init?(source: URL, layout: UInt64) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            sourceSize = size.uint64Value
            sourceModified = Int64(modified.timeIntervalSince1970 * 1_000)
            self.layout = layout
        }

        init(sourceSize: UInt64, sourceModified: Int64, layout: UInt64) {
            self.sourceSize = sourceSize
            self.sourceModified = sourceModified
            self.layout = layout
        }
    }

    static func url(for source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("cache")
    }

    /// Writes the tables (raw bytes and record counts) atomically. Failures are ignored: the
    /// cache is only an optimization.
    static func write(_ tables: [(bytes: Data, count: Int)], stamp: Stamp, to url: URL) {
        guard tables.count <= maximumSections else { return }
        var header = Data(count: headerSize)
        var body = Data()
        var trailer = Data()
        var offsets: [(UInt64, UInt64)] = []
        for table in tables {
            let padding = (16 - (headerSize + body.count) % 16) % 16
            body.append(Data(count: padding))
            offsets.append((UInt64(headerSize + body.count), UInt64(table.count)))
            body.append(table.bytes)
        }
        // The section table goes at the end of the file: (offset, count) pairs of 16 bytes.
        for (offset, count) in offsets {
            withUnsafeBytes(of: offset) { trailer.append(contentsOf: $0) }
            withUnsafeBytes(of: count) { trailer.append(contentsOf: $0) }
        }
        let payload = body + trailer
        let sum = checksum(payload)
        header.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: sum, toByteOffset: 40, as: UInt64.self)
            raw.storeBytes(of: magic.littleEndian, toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: stamp.layout, toByteOffset: 8, as: UInt64.self)
            raw.storeBytes(of: stamp.sourceSize, toByteOffset: 16, as: UInt64.self)
            raw.storeBytes(of: stamp.sourceModified, toByteOffset: 24, as: Int64.self)
            raw.storeBytes(of: UInt32(tables.count), toByteOffset: 32, as: UInt32.self)
        }
        try? (header + payload).write(to: url, options: .atomic)
    }

    /// The sections of a valid cache, mapped; `nil` when there is none, it is stale, or anything
    /// in it does not add up.
    static func read(from url: URL, stamp: Stamp, sections expected: Int) -> [Section]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count >= headerSize + expected * 16 else { return nil }
        let (magicValue, layout, size, modified, count) = data.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
             raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
             raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
             raw.loadUnaligned(fromByteOffset: 24, as: Int64.self),
             raw.loadUnaligned(fromByteOffset: 32, as: UInt32.self))
        }
        guard UInt64(littleEndian: magicValue) == magic, count == expected,
              Stamp(sourceSize: size, sourceModified: modified, layout: layout) == stamp else { return nil }
        // Structure checks keep reads in bounds; the checksum catches a damaged record that would
        // otherwise give a wrong answer.
        let stored = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
        guard checksum(data.suffix(from: headerSize)) == stored else { return nil }
        let trailerStart = data.count - expected * 16
        var sections: [Section] = []
        for i in 0..<expected {
            let (offset, records) = data.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: trailerStart + i * 16, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: trailerStart + i * 16 + 8, as: UInt64.self))
            }
            guard offset >= UInt64(headerSize), offset <= UInt64(trailerStart), records <= UInt64(Int32.max) else { return nil }
            sections.append(Section(data: data.prefix(trailerStart), offset: Int(offset), count: Int(records)))
        }
        return sections
    }

    /// A fast 64-bit hash, 8 bytes at a time (about 10 ms for the country cache). It detects
    /// damage; it is not a defense against someone who can rewrite the CSV next to it anyway.
    static func checksum(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { raw in
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            let words = raw.count / 8
            for i in 0..<words {
                hash = (hash ^ raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x100_0000_01B3
                hash ^= hash >> 29
            }
            for i in (words * 8)..<raw.count {
                hash = (hash ^ UInt64(raw[i])) &* 0x100_0000_01B3
            }
            return hash
        }
    }

    /// Identifies the record layout of this build, so a cache written by another architecture or
    /// version is rebuilt instead of misread.
    static func layout(_ strides: [Int], version: UInt64) -> UInt64 {
        var value = version &* 0x9E37_79B9_7F4A_7C15
        for stride in strides { value = (value ^ UInt64(stride)) &* 0x100_0000_01B3 }
        #if arch(arm64)
        value ^= 0xA1
        #else
        value ^= 0xB2
        #endif
        return value
    }
}
