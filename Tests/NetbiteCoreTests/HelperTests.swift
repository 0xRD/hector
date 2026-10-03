import Foundation
import Testing
@testable import NetbiteCore

@Suite struct BlockMatcherTests {
    static let blocklist = Blocklist(rules: [
        Rule(target: RuleTarget("203.0.113.0/24")!),
        Rule(target: RuleTarget("198.51.100.17")!),
        Rule(target: RuleTarget("192.0.2.1")!, isEnabled: false),
        Rule(target: RuleTarget("tracker.example.com")!),
    ], blockedCountries: ["RU"])

    @Test func matchesNetworksThenCountries() {
        let blocklist = Self.blocklist
        #expect(blocklist.blockReason(for: IPAddress("203.0.113.9")!, country: "US") == .network(CIDR("203.0.113.0/24")!))
        #expect(blocklist.blockReason(for: IPAddress("198.51.100.17")!, country: nil) == .network(CIDR("198.51.100.17")!))
        #expect(blocklist.blockReason(for: IPAddress("5.8.1.1")!, country: "RU") == .country("RU"))
        #expect(blocklist.blockReason(for: IPAddress("1.1.1.1")!, country: "AU") == nil)
    }

    @Test func ignoresDisabledRules() {
        #expect(Self.blocklist.blockReason(for: IPAddress("192.0.2.1")!, country: nil) == nil)
    }

    @Test func findsTheExactAddressRule() {
        #expect(Self.blocklist.addressRule(for: IPAddress("198.51.100.17")!) != nil)
        #expect(Self.blocklist.addressRule(for: IPAddress("203.0.113.9")!) == nil)
    }
}

@Suite struct HelperProtocolTests {
    @Test func wireEncodingIsASingleLine() throws {
        let token = Data(repeating: 7, count: 32)
        let request = HelperRequest.apply(BlockMatcherTests.blocklist, authorization: token)
        let data = try JSONEncoder.netbiteWire.encode(request)
        #expect(!data.contains(UInt8(ascii: "\n")))
        guard case .apply(let decoded, let authorization) = try JSONDecoder.netbite.decode(HelperRequest.self, from: data) else {
            Issue.record("Decoded the wrong request")
            return
        }
        #expect(decoded == BlockMatcherTests.blocklist)
        #expect(authorization == token)
    }

    @Test func statusRoundTrips() throws {
        let status = HelperStatus(version: "0.3.0", pfEnabled: true, anchorLoaded: true, appliedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                  blocklist: nil, blockTableCount: 2, geoTableCount: 38348, hostsDomainCount: 1, warnings: ["w"])
        let data = try JSONEncoder.netbiteWire.encode(HelperResponse.status(status))
        guard case .status(let decoded) = try JSONDecoder.netbite.decode(HelperResponse.self, from: data) else {
            Issue.record("Decoded the wrong response")
            return
        }
        #expect(decoded == status)
    }

    @Test func refusesSocketPathsThatDoNotFit() {
        #expect(throws: LineSocket.SocketError.self) { try LineSocket.address(String(repeating: "a", count: 200)) }
        #expect(throws: Never.self) { try LineSocket.address(HelperPaths.socket) }
    }
}
