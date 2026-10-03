import Darwin

/// An IPv4 or IPv6 address stored as a host-order integer.
public enum IPAddress: Hashable, Sendable {
    case v4(UInt32)
    case v6(UInt128)

    /// Parses a textual address (`"140.82.121.4"`, `"2a00:1450::1"`).
    public init?(_ string: String) {
        var a4 = in_addr()
        if inet_pton(AF_INET, string, &a4) == 1 {
            self = .v4(UInt32(bigEndian: a4.s_addr))
            return
        }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, string, &a6) == 1 {
            self.init(a6)
            return
        }
        return nil
    }

    /// Builds an address from a kernel `in_addr` (network byte order).
    public init(_ addr: in_addr) {
        self = .v4(UInt32(bigEndian: addr.s_addr))
    }

    /// Builds an address from a kernel `in6_addr`.
    public init(_ addr: in6_addr) {
        let value = withUnsafeBytes(of: addr) { raw in
            raw.reduce(UInt128(0)) { ($0 << 8) | UInt128($1) }
        }
        self = .v6(value)
    }

    /// The address as it should be displayed and matched:
    /// - IPv4-mapped (`::ffff:a.b.c.d`) and IPv4-compatible (`::a.b.c.d`) addresses become IPv4;
    /// - the interface index the kernel embeds in link-local addresses (`fe80:16::…`) is cleared.
    public var normalized: IPAddress {
        guard case .v6(let value) = self else { return self }
        let high = value >> 32
        if (high == 0xFFFF || high == 0) && value > 1 {
            return .v4(UInt32(truncatingIfNeeded: value))
        }
        if value >> 118 == 0x3FA {  // fe80::/10
            return .v6(value & ~(UInt128(0xFFFF) << 96))
        }
        return self
    }

    /// 32 for IPv4, 128 for IPv6.
    public var bitWidth: Int {
        switch self {
        case .v4: 32
        case .v6: 128
        }
    }

    public var isV4: Bool {
        if case .v4 = self { return true }
        return false
    }

    /// Loopback, private, link-local, CGNAT, multicast and unspecified ranges.
    /// These never belong in a block table: blocking them breaks the local machine or LAN.
    public var isLocalOrPrivate: Bool {
        Self.localNetworks.contains { $0.contains(self) }
    }

    static let localNetworks: [CIDR] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "255.255.255.255/32",
        "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
    ].compactMap { CIDR($0) }
}

extension IPAddress: CustomStringConvertible {
    public var description: String {
        switch self {
        case .v4(let value):
            var addr = in_addr(s_addr: value.bigEndian)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        case .v6(let value):
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { raw in
                for i in 0..<16 {
                    raw[i] = UInt8(truncatingIfNeeded: value >> UInt128((15 - i) * 8))
                }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
    }
}

extension IPAddress: Comparable {
    /// IPv4 sorts before IPv6; within a family, numeric order.
    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case (.v4(let a), .v4(let b)): a < b
        case (.v6(let a), .v6(let b)): a < b
        case (.v4, .v6): true
        case (.v6, .v4): false
        }
    }
}

extension IPAddress: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let address = IPAddress(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP address: \(string)")
        }
        self = address
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
