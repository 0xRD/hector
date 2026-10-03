import Foundation
import Testing
@testable import HectorCore

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
        let data = try JSONEncoder.hectorWire.encode(request)
        #expect(!data.contains(UInt8(ascii: "\n")))
        guard case .apply(let decoded, let authorization) = try JSONDecoder.hector.decode(HelperRequest.self, from: data) else {
            Issue.record("Decoded the wrong request")
            return
        }
        #expect(decoded == BlockMatcherTests.blocklist)
        #expect(authorization == token)
    }

    @Test func statusRoundTrips() throws {
        let status = HelperStatus(version: "0.3.0", pfEnabled: true, anchorLoaded: true, appliedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                  blocklist: nil, blockTableCount: 2, geoTableCount: 38348, hostsDomainCount: 1, warnings: ["w"])
        let data = try JSONEncoder.hectorWire.encode(HelperResponse.status(status))
        guard case .status(let decoded) = try JSONDecoder.hector.decode(HelperResponse.self, from: data) else {
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

@Suite struct LegacyMigrationTests {
    @Test func movesNetbiteDataOnlyWhenHectorHasNone() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "hector-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appending(path: "Netbite")
        let current = base.appending(path: "Hector")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appending(path: "blocklist.json"))

        #expect(LegacyMigration.moveUserData(from: legacy, to: current))
        #expect(FileManager.default.fileExists(atPath: current.appending(path: "blocklist.json").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // Nothing left to move, and an existing Hector folder is never overwritten.
        #expect(!LegacyMigration.moveUserData(from: legacy, to: current))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(!LegacyMigration.moveUserData(from: legacy, to: current))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func legacyNamesAreNotHectors() {
        #expect(LegacyPaths.helperLabel != HelperPaths.label)
        #expect(LegacyPaths.dataDirectory != HelperPaths.dataDirectory)
        #expect(LegacyPaths.keychainService != APIKeyStore.virusTotalService)
        #expect(LegacyPaths.authorizationRight != HelperAuthorization.rightName)
    }
}

@Suite struct HelperHandshakeTests {
    @Test func everyRequestMapsToACapabilityTheHelperAnnounces() {
        let requests: [HelperRequest] = [
            .hello, .status, .snapshot, .processes, .backgroundTasks,
            .apply(Blocklist(), authorization: Data()), .flush(authorization: Data()),
            .refreshHostsLists(authorization: Data()),
        ]
        let current = HelperInfo.current
        #expect(Set(requests.map(\.capability)) == Set(HelperCapability.allCases))
        #expect(requests.allSatisfy { current.supports($0.capability) })
        #expect(!current.isOutdated)
        // Only what touches the rules is serialized; snapshots never wait behind an apply.
        #expect(requests.filter(\.touchesRules).map(\.capability).sorted { $0.rawValue < $1.rawValue }
                == [.apply, .flush, .refreshHostsLists, .status])
    }

    @Test func legacyHelpersAreOutdatedAndLackTheNewRequests() {
        let legacy = HelperInfo.legacy
        #expect(legacy.isOutdated)
        #expect(legacy.supports(.status) && legacy.supports(.snapshot) && legacy.supports(.apply) && legacy.supports(.flush))
        #expect(!legacy.supports(.processes) && !legacy.supports(.backgroundTasks) && !legacy.supports(.refreshHostsLists))
    }

    @Test func helloRoundTripsAndToleratesUnknownCapabilities() throws {
        let reply = HelperResponse.hello(HelperInfo(version: "9.9.9", protocolVersion: 7,
                                                    capabilities: HelperCapability.allCases.map(\.rawValue) + ["teleport"]))
        let decoded = try JSONDecoder.hector.decode(HelperResponse.self, from: JSONEncoder.hectorWire.encode(reply))
        guard case .hello(let info) = decoded else { Issue.record("not a hello"); return }
        #expect(info.version == "9.9.9")
        #expect(info.capabilities.contains("teleport"))
        #expect(!info.isOutdated)
        let request = try JSONDecoder.hector.decode(HelperRequest.self, from: JSONEncoder.hectorWire.encode(HelperRequest.hello))
        #expect(request.capability == .hello)
    }

    @Test func anOlderHelperCannotDecodeHello() throws {
        // What a pre-handshake helper does with the request: its enum has no `hello` case, so
        // decoding fails and it answers with a failure, which the client reads as `legacy`.
        enum OldRequest: Codable { case status, snapshot }
        let data = try JSONEncoder.hectorWire.encode(HelperRequest.hello)
        #expect(throws: DecodingError.self) { try JSONDecoder.hector.decode(OldRequest.self, from: data) }
    }
}
