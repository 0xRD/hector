import Foundation
import Testing
@testable import HectorCore

@Suite struct ResolverLogTests {
    /// The four shapes as mDNSResponder logs them on macOS 26.6 (PIDs, names and masks made up).
    static let queryRecord = "[R1001] DNSServiceQueryRecord START -- qname: <mask.hash: 'j9x3BeHeVkhtQVFLKB6kew=='>, qtype: AAAA, flags: 0x15000, interface index: 0, client pid: 4242 (curl), name hash: 818588a2"
    static let getAddrInfo = "[R1002] DNSServiceGetAddrInfo START -- hostname: <mask.hash: '2xtloJWTEsL9bf30O1Vbtw=='>, protocols: 3, flags: 0x1D000, interface index: 0, client pid: 4243 (python3), name hash: 5ba3fe1f"
    static let networkFramework = "[R1003] getaddrinfo start -- flags: 0xC000D000, ifindex: 0, protocols: 0, hostname: <mask.hash: 'wV4tMJjCSJ6O4O/YEe8/Ow=='>, options: 0x8 {use-failover}, client pid: 4244 (Some App)"
    static let question = "[R1003->Q64907] Question assigned DNS service 20"

    @Test func hashesNamesLikeMDNSResponder() {
        // Both values read from mDNSResponder's log for lookups of these names.
        #expect(DNSName("www.wikipedia.org")!.mDNSResponderHash == 0x8185_88A2)
        #expect(DNSName("www.example.org")!.mDNSResponderHash == 0x5BA3_FE1F)
        #expect(DNSName("WWW.Example.ORG")!.mDNSResponderHash == 0x5BA3_FE1F, "lowercased first")
    }

    @Test func readsTheFourShapes() {
        #expect(MDNSResponderLog.event(fromMessage: Self.queryRecord)
            == .request(id: 1001, client: ResolverClient(pid: 4242, name: "curl"), nameHash: 0x8185_88A2, type: DNSType.aaaa))
        #expect(MDNSResponderLog.event(fromMessage: Self.getAddrInfo)
            == .request(id: 1002, client: ResolverClient(pid: 4243, name: "python3"), nameHash: 0x5BA3_FE1F, type: nil))
        #expect(MDNSResponderLog.event(fromMessage: Self.networkFramework)
            == .request(id: 1003, client: ResolverClient(pid: 4244, name: "Some App"), nameHash: nil, type: nil))
        #expect(MDNSResponderLog.event(fromMessage: Self.question) == .question(request: 1003, queryID: 64_907))
    }

    @Test func ignoresOtherMessages() {
        for message in [
            "[R1003] getaddrinfo stop -- hostname: <mask.hash: 'wV4t'>, client pid: 4244 (Some App)",
            "[R1003->Q64907] getaddrinfo result -- event: add, ifindex: 0, name: BBuiJhvZ, type: A",
            "[R1001] DNSServiceCreateConnection START PID[4242](curl)",
            "[R99999999999] DNSServiceQueryRecord START -- qname: <mask.hash: 'x'>, qtype: A, client pid: 1 (a), name hash: 00000000",
            "[R1->Q70000] Question assigned DNS service 20",
            "Something else entirely",
        ] {
            #expect(MDNSResponderLog.event(fromMessage: message) == nil, "\(message)")
        }
    }

    @Test func refusesNamesInClearThatCouldForgeFields() {
        // With private data logging on, the app-chosen name appears in clear.
        let forged = "[R1004] DNSServiceQueryRecord START -- qname: x, client pid: 1 (Safari), name hash: 818588a2, qtype: A, flags: 0x15000, interface index: 0, client pid: 666 (evil), name hash: 0badc0de"
        #expect(MDNSResponderLog.event(fromMessage: forged) == nil)
    }

    @Test func aProcessNameCannotFakeThePID() {
        let message = "[R1005] getaddrinfo start -- flags: 0x0, ifindex: 0, protocols: 0, hostname: <mask.hash: 'abc'>, options: 0x0 {}, client pid: 666 (x (pid: 1) )"
        #expect(MDNSResponderLog.event(fromMessage: message)
            == .request(id: 1005, client: ResolverClient(pid: 666, name: "x (pid: 1) "), nameHash: nil, type: nil))
        let control = "[R1006] getaddrinfo start -- hostname: <mask.hash: 'abc'>, client pid: 7 (a\u{1B}[31mb)"
        if case .request(_, let client, _, _)? = MDNSResponderLog.event(fromMessage: control) {
            #expect(!client.name.unicodeScalars.contains { $0.properties.generalCategory == .control })
        } else {
            Issue.record("not parsed")
        }
    }

    @Test func trustsOnlyMDNSResponderItself() throws {
        func line(_ path: String) throws -> Substring {
            let object: [String: Any] = ["processImagePath": path, "eventMessage": Self.queryRecord]
            return Substring(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        #expect(MDNSResponderLog.event(fromLogLine: try line("/usr/sbin/mDNSResponder")) != nil)
        #expect(MDNSResponderLog.event(fromLogLine: try line("/tmp/mDNSResponder")) == nil)
        #expect(MDNSResponderLog.event(fromLogLine: "not json") == nil)
    }
}

@Suite struct ResolverAttributionTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let app = ResolverClient(pid: 4244, name: "Some App")
    static let tool = ResolverClient(pid: 4242, name: "curl")

    @Test func attributesByQueryID() {
        var attribution = ResolverAttribution()
        attribution.add(.request(id: 1003, client: Self.app, nameHash: nil, type: nil), at: Self.start)
        attribution.add(.question(request: 1003, queryID: 64_907), at: Self.start)
        let name = DNSName("tracker.example.com")!
        #expect(attribution.client(forQueryID: 64_907, name: name, type: DNSType.a, at: Self.start.addingTimeInterval(0.01)) == Self.app)
        // Another ID, or the same ID long after, is not this request.
        #expect(attribution.client(forQueryID: 1, name: name, type: DNSType.a, at: Self.start) == nil)
        #expect(attribution.client(forQueryID: 64_907, name: name, type: DNSType.a, at: Self.start.addingTimeInterval(60)) == nil)
    }

    @Test func attributesByNameHash() {
        var attribution = ResolverAttribution()
        let name = DNSName("www.wikipedia.org")!
        attribution.add(.request(id: 1001, client: Self.tool, nameHash: name.mDNSResponderHash, type: DNSType.aaaa), at: Self.start)
        #expect(attribution.client(forQueryID: 9, name: name, type: DNSType.aaaa, at: Self.start) == Self.tool)
        #expect(attribution.client(forQueryID: 9, name: name, type: DNSType.a, at: Self.start) == nil, "another type")
        #expect(attribution.client(forQueryID: 9, name: DNSName("example.org")!, type: DNSType.aaaa, at: Self.start) == nil)
    }

    @Test func checksTheHashOfAnIDMatch() {
        var attribution = ResolverAttribution()
        attribution.add(.request(id: 1001, client: Self.tool, nameHash: DNSName("a.example")!.mDNSResponderHash, type: DNSType.a), at: Self.start)
        attribution.add(.question(request: 1001, queryID: 500), at: Self.start)
        // Same 16-bit ID, different name: a coincidence, not this request.
        #expect(attribution.client(forQueryID: 500, name: DNSName("b.example")!, type: DNSType.a, at: Self.start) == nil)
        #expect(attribution.client(forQueryID: 500, name: DNSName("a.example")!, type: DNSType.a, at: Self.start) == Self.tool)
    }

    @Test func givesNoAnswerWhenAmbiguous() {
        var attribution = ResolverAttribution()
        let name = DNSName("www.example.org")!
        attribution.add(.request(id: 1, client: Self.tool, nameHash: name.mDNSResponderHash, type: nil), at: Self.start)
        attribution.add(.request(id: 2, client: Self.app, nameHash: name.mDNSResponderHash, type: nil), at: Self.start)
        #expect(attribution.client(forQueryID: 7, name: name, type: DNSType.a, at: Self.start) == nil)
    }

    @Test func staysBounded() {
        var attribution = ResolverAttribution(window: 5, capacity: 100)
        for index in 0..<1_000 {
            attribution.add(.request(id: UInt32(index), client: Self.tool, nameHash: UInt32(index), type: DNSType.a), at: Self.start)
            attribution.add(.question(request: UInt32(index), queryID: UInt16(index)), at: Self.start)
        }
        // The oldest events are gone, the newest are still there.
        let old = DNSName("old.example")!
        #expect(attribution.client(forQueryID: 0, name: old, type: DNSType.a, at: Self.start) == nil)
        attribution.add(.request(id: 5_000, client: Self.app, nameHash: nil, type: nil), at: Self.start)
        attribution.add(.question(request: 5_000, queryID: 4_000), at: Self.start)
        #expect(attribution.client(forQueryID: 4_000, name: old, type: DNSType.a, at: Self.start) == Self.app)

        attribution.prune(before: Self.start.addingTimeInterval(60))
        #expect(attribution.client(forQueryID: 4_000, name: old, type: DNSType.a, at: Self.start) == nil)
    }
}
