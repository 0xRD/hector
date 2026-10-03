import Darwin

/// PTR lookups. Note that a PTR name (`fra16s50-in-f4.1e100.net`) is the network's name for the
/// address, not necessarily the host name the app asked for.
public enum ReverseDNS {
    /// Blocking lookup through the system resolver; `nil` when the address has no PTR record.
    /// Call it off the main thread: a missing record can take seconds to time out.
    public static func lookup(_ address: IPAddress) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status: Int32
        if address.isV4 {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, address.description, &sa.sin_addr)
            status = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else {
            var sa = sockaddr_in6()
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa.sin6_family = sa_family_t(AF_INET6)
            inet_pton(AF_INET6, address.description, &sa.sin6_addr)
            status = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        }
        guard status == 0 else { return nil }
        let name = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        // The resolver echoes the address back when it has nothing better.
        return name == address.description ? nil : name
    }
}
