import Foundation

/// An IP network such as `203.0.113.0/24`. A single address is a /32 (IPv4) or /128 (IPv6).
public struct CIDR: Hashable, Sendable {
    /// The network address, with host bits cleared.
    public let network: IPAddress
    public let prefixLength: Int

    public init(network: IPAddress, prefixLength: Int) {
        let prefix = max(0, min(prefixLength, network.bitWidth))
        switch network {
        case .v4(let value):
            self.network = .v4(value & (UInt32.max << (32 - prefix)))
        case .v6(let value):
            self.network = .v6(value & (UInt128.max << (128 - prefix)))
        }
        self.prefixLength = prefix
    }

    /// Parses `"a.b.c.d/n"`, `"x::/n"` or a bare address.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let address = IPAddress(String(parts[0])) else { return nil }
        var prefix = address.bitWidth
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...address.bitWidth).contains(parsed) else { return nil }
            prefix = parsed
        }
        self.init(network: address, prefixLength: prefix)
    }

    public init(_ address: IPAddress) {
        self.init(network: address, prefixLength: address.bitWidth)
    }

    public var isSingleAddress: Bool { prefixLength == network.bitWidth }

    public func contains(_ address: IPAddress) -> Bool {
        switch (network, address) {
        case (.v4(let net), .v4(let value)):
            value & (UInt32.max << (32 - prefixLength)) == net
        case (.v6(let net), .v6(let value)):
            value & (UInt128.max << (128 - prefixLength)) == net
        default:
            false
        }
    }

    /// The smallest list of networks that exactly covers `lower...upper` (same family, inclusive).
    public static func covering(from lower: IPAddress, to upper: IPAddress) -> [CIDR] {
        switch (lower, upper) {
        case (.v4(let lo), .v4(let hi)) where lo <= hi:
            covering(lo, hi).map { CIDR(network: .v4($0.start), prefixLength: $0.prefix) }
        case (.v6(let lo), .v6(let hi)) where lo <= hi:
            covering(lo, hi).map { CIDR(network: .v6($0.start), prefixLength: $0.prefix) }
        default:
            []
        }
    }

    private static func covering<T: FixedWidthInteger & UnsignedInteger>(_ lo: T, _ hi: T) -> [(start: T, prefix: Int)] {
        let bits = T.bitWidth
        var blocks: [(start: T, prefix: Int)] = []
        var start = lo
        while true {
            // Largest block aligned on `start`, then shrink it until it ends at or before `hi`.
            var size = start == 0 ? bits : start.trailingZeroBitCount
            while size > 0 {
                let span = T.max >> (bits - size)
                let (end, overflow) = start.addingReportingOverflow(span)
                if !overflow && end <= hi { break }
                size -= 1
            }
            blocks.append((start, bits - size))
            let end = start &+ (size == 0 ? 0 : T.max >> (bits - size))
            if end >= hi { break }
            start = end + 1
        }
        return blocks
    }
}

extension CIDR: CustomStringConvertible {
    public var description: String {
        isSingleAddress ? network.description : "\(network)/\(prefixLength)"
    }
}

extension CIDR: Comparable {
    public static func < (lhs: CIDR, rhs: CIDR) -> Bool {
        lhs.network == rhs.network ? lhs.prefixLength < rhs.prefixLength : lhs.network < rhs.network
    }
}

extension CIDR: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let cidr = CIDR(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid network: \(string)")
        }
        self = cidr
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
