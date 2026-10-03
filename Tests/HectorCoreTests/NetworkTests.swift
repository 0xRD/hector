import Testing
@testable import HectorCore

@Suite struct IPAddressTests {
    @Test func parsesAndFormatsBothFamilies() throws {
        #expect(IPAddress("140.82.121.4")?.description == "140.82.121.4")
        #expect(IPAddress("2A00:1450:4007:80C::200E")?.description == "2a00:1450:4007:80c::200e")
        #expect(IPAddress("not an ip") == nil)
        #expect(IPAddress("256.1.1.1") == nil)
    }

    @Test func normalizesMappedAndScopedAddresses() throws {
        #expect(IPAddress("::ffff:192.0.2.232")!.normalized == IPAddress("192.0.2.232"))
        #expect(IPAddress("::192.0.2.232")!.normalized == IPAddress("192.0.2.232"))
        #expect(IPAddress("fe80:16::1234:5678:9abc:def0")!.normalized == IPAddress("fe80::1234:5678:9abc:def0"))
        #expect(IPAddress("::1")!.normalized == IPAddress("::1"))
        #expect(IPAddress("2a00::1")!.normalized == IPAddress("2a00::1"))
    }

    @Test func recognisesLocalAndPrivateRanges() {
        for local in ["127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.10", "169.254.1.1", "::1", "fe80::1", "fd00::1"] {
            #expect(IPAddress(local)!.isLocalOrPrivate, "\(local)")
        }
        for global in ["1.1.1.1", "140.82.121.4", "172.32.0.1", "2a00:1450::1"] {
            #expect(!IPAddress(global)!.isLocalOrPrivate, "\(global)")
        }
    }

    @Test func sortsIPv4BeforeIPv6() {
        let sorted = ["2a00::1", "9.9.9.9", "1.1.1.1"].compactMap(IPAddress.init).sorted()
        #expect(sorted.map(\.description) == ["1.1.1.1", "9.9.9.9", "2a00::1"])
    }
}

@Suite struct CIDRTests {
    @Test func parsesAndClearsHostBits() {
        #expect(CIDR("203.0.113.77/24")?.description == "203.0.113.0/24")
        #expect(CIDR("198.51.100.17")?.description == "198.51.100.17")
        #expect(CIDR("2001:db8::1/32")?.description == "2001:db8::/32")
        #expect(CIDR("10.0.0.0/33") == nil)
        #expect(CIDR("10.0.0.0/x") == nil)
    }

    @Test func containsAddresses() {
        let net = CIDR("203.0.113.0/24")!
        #expect(net.contains(IPAddress("203.0.113.255")!))
        #expect(!net.contains(IPAddress("203.0.114.0")!))
        #expect(!net.contains(IPAddress("2001:db8::1")!))
        #expect(CIDR("0.0.0.0/0")!.contains(IPAddress("8.8.8.8")!))
    }

    @Test func coversRangesExactly() {
        let blocks = CIDR.covering(from: IPAddress("1.0.0.0")!, to: IPAddress("1.0.3.255")!)
        #expect(blocks.map(\.description) == ["1.0.0.0/22"])

        let odd = CIDR.covering(from: IPAddress("10.0.0.1")!, to: IPAddress("10.0.0.6")!)
        #expect(odd.map(\.description) == ["10.0.0.1", "10.0.0.2/31", "10.0.0.4/31", "10.0.0.6"])

        let everything = CIDR.covering(from: IPAddress("0.0.0.0")!, to: IPAddress("255.255.255.255")!)
        #expect(everything.map(\.description) == ["0.0.0.0/0"])

        let v6 = CIDR.covering(from: IPAddress("2001:db8::")!, to: IPAddress("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff")!)
        #expect(v6.map(\.description) == ["2001:db8::/32"])

        #expect(CIDR.covering(from: IPAddress("10.0.0.5")!, to: IPAddress("10.0.0.1")!).isEmpty)
        #expect(CIDR.covering(from: IPAddress("10.0.0.1")!, to: IPAddress("::1")!).isEmpty)
    }
}
