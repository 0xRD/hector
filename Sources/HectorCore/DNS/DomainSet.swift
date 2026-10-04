import Foundation

/// An immutable set of domains, each matching either the name alone or the name and all of its
/// subdomains, compact enough for the 400,000 names of several lists.
///
/// The names live sorted in one byte buffer with a 32-bit offset each (about 25 bytes per name
/// instead of the 60 or more of a `Set<String>`), plus one bit per name for "with subdomains". A
/// lookup checks the name, then each parent at a label boundary, by binary search: at most one
/// search per label, about 19 comparisons each for 400,000 names, with no allocation.
public struct DomainSet: Sendable {
    /// Every name, lowercased, sorted bytewise, without separators.
    private let storage: [UInt8]
    /// `offsets[i]..<offsets[i + 1]` is name `i`; one more entry than there are names.
    private let offsets: [UInt32]
    /// Bit `i` is set when name `i` also covers its subdomains.
    private let subtreeBits: [UInt64]

    /// What a lookup found.
    public struct Match: Hashable, Sendable {
        /// The entry that matched: the name itself, or the parent that covers it.
        public let entry: String
        public let includesSubdomains: Bool
    }

    public static let empty = DomainSet(exact: [], subtrees: [])

    /// Names are taken lowercased, without a trailing dot; empty names and names over 253 bytes
    /// are dropped (callers pass names validated by `DomainPattern`). A name given both ways keeps
    /// the wider meaning.
    public init<Exact: Sequence<String>, Subtrees: Sequence<String>>(exact: Exact, subtrees: Subtrees) {
        var entries: [(name: [UInt8], subtree: Bool)] = []
        for name in exact {
            if let bytes = Self.normalized(name) { entries.append((bytes, false)) }
        }
        for name in subtrees {
            if let bytes = Self.normalized(name) { entries.append((bytes, true)) }
        }
        // Equal names sort with the subtree entry first, so it is the one kept.
        entries.sort { left, right in
            if left.name != right.name { return left.name.lexicographicallyPrecedes(right.name) }
            return left.subtree && !right.subtree
        }

        var storage: [UInt8] = []
        var offsets: [UInt32] = [0]
        var bits: [UInt64] = []
        var previous: [UInt8]?
        for entry in entries where entry.name != previous {
            let index = offsets.count - 1
            if index % 64 == 0 { bits.append(0) }
            if entry.subtree { bits[index / 64] |= UInt64(1) << UInt64(index % 64) }
            storage.append(contentsOf: entry.name)
            offsets.append(UInt32(storage.count))
            previous = entry.name
        }
        self.storage = storage
        self.offsets = offsets
        self.subtreeBits = bits
    }

    private static func normalized(_ name: String) -> [UInt8]? {
        var bytes = Array(name.utf8)
        if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
        guard (1...253).contains(bytes.count) else { return nil }
        return bytes.map(DNSName.asciiLower)
    }

    public var count: Int { offsets.count - 1 }

    public var isEmpty: Bool { count == 0 }

    /// Bytes held by the set, for the memory budget.
    public var byteCount: Int {
        storage.count + offsets.count * MemoryLayout<UInt32>.size + subtreeBits.count * MemoryLayout<UInt64>.size
    }

    /// The most specific entry that covers `name`: the name itself (exact or with subdomains),
    /// else the nearest parent added with its subdomains. Case and a trailing dot are ignored.
    public func match(_ name: String) -> Match? {
        var bytes = Array(name.utf8)
        if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
        guard !bytes.isEmpty, !isEmpty else { return nil }
        for index in bytes.indices { bytes[index] = DNSName.asciiLower(bytes[index]) }

        return bytes.withUnsafeBufferPointer { query -> Match? in
            var start = 0
            while start < query.count {
                let suffix = UnsafeBufferPointer(rebasing: query[start...])
                if let index = find(suffix) {
                    let subtree = isSubtree(index)
                    // The name itself matches either way; a parent only if it covers subdomains.
                    if start == 0 || subtree {
                        return Match(entry: String(decoding: suffix, as: UTF8.self), includesSubdomains: subtree)
                    }
                }
                // The next parent starts after the next dot.
                guard let dot = query[start...].firstIndex(of: UInt8(ascii: ".")) else { break }
                start = dot + 1
            }
            return nil
        }
    }

    public func contains(_ name: String) -> Bool {
        match(name) != nil
    }

    /// Every entry, in sorted order: for tests and for writing a compiled set back out.
    public var entries: [(name: String, includesSubdomains: Bool)] {
        (0..<count).map { index in
            let range = Int(offsets[index])..<Int(offsets[index + 1])
            return (String(decoding: storage[range], as: UTF8.self), isSubtree(index))
        }
    }

    private func isSubtree(_ index: Int) -> Bool {
        subtreeBits[index / 64] & (UInt64(1) << UInt64(index % 64)) != 0
    }

    /// Binary search for an entry equal to `key`.
    private func find(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
        storage.withUnsafeBufferPointer { buffer -> Int? in
            var low = 0
            var high = count
            while low < high {
                let middle = low + (high - low) / 2
                let entry = UnsafeBufferPointer(rebasing: buffer[Int(offsets[middle])..<Int(offsets[middle + 1])])
                let order = Self.compare(entry, key)
                if order == 0 { return middle }
                if order < 0 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return nil
        }
    }

    /// Bytewise order, the order `lexicographicallyPrecedes` sorted the entries in.
    private static func compare(_ left: UnsafeBufferPointer<UInt8>, _ right: UnsafeBufferPointer<UInt8>) -> Int {
        let shared = min(left.count, right.count)
        if shared > 0, let a = left.baseAddress, let b = right.baseAddress {
            let order = memcmp(a, b, shared)
            if order != 0 { return Int(order) }
        }
        return left.count - right.count
    }
}
