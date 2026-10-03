import Foundation
import Testing
@testable import HectorCore

/// Random and mutated inputs for everything that reads data from outside: the helper's request
/// decoder, hosts lists, the DB-IP files, blocklists and `sfltool` output. None may crash, and
/// whatever they accept must still be valid. Seeded, so a failure can be replayed.
@Suite struct FuzzTests {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var x = state
            x ^= x >> 33
            return x
        }
    }

    private static let alphabet = Array("0123456789abcdefxyz.:,-_ \"\\{}[]#\n\r\t\u{0}\u{1b}é😀/".utf8)

    private func randomBytes(_ count: Int, _ rng: inout Generator) -> Data {
        Data((0..<count).map { _ in
            Bool.random(using: &rng) ? Self.alphabet.randomElement(using: &rng)! : UInt8.random(in: 0...255, using: &rng)
        })
    }

    private func mutate(_ data: Data, _ rng: inout Generator) -> Data {
        var bytes = [UInt8](data)
        for _ in 0..<Int.random(in: 1...8, using: &rng) {
            guard !bytes.isEmpty else { break }
            let index = Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0...3, using: &rng) {
            case 0: bytes[index] = UInt8.random(in: 0...255, using: &rng)
            case 1: bytes.remove(at: index)
            case 2: bytes.insert(Self.alphabet.randomElement(using: &rng)!, at: index)
            default: bytes.insert(contentsOf: bytes[index..<min(bytes.count, index + 16)], at: index)
            }
        }
        return Data(bytes)
    }

    @Test func helperRequestsDecodeSafely() throws {
        var rng = Generator(state: 1)
        let blocklist = Blocklist(rules: [Rule(target: RuleTarget("tracker.example.com")!)], blockedCountries: ["KP"], hostsLists: ["easyprivacy"])
        let seeds: [HelperRequest] = [.status, .snapshot, .processes, .backgroundTasks, .hello,
                                      .apply(blocklist, authorization: Data(count: 32)), .flush(authorization: Data()),
                                      .refreshHostsLists(authorization: Data())]
        let encoded = try seeds.map { try JSONEncoder.hectorWire.encode($0) }
        for round in 0..<4_000 {
            let input = round % 4 == 0 ? randomBytes(Int.random(in: 0...200, using: &rng), &rng)
                                       : mutate(encoded.randomElement(using: &rng)!, &rng)
            if case .apply(let decoded, _)? = try? JSONDecoder.hector.decode(HelperRequest.self, from: input) {
                // A decoded blocklist goes through the helper's limits before anything else.
                _ = try? HelperLimits.validate(decoded)
            }
        }
    }

    @Test func hostsListsOnlyYieldValidDomains() {
        var rng = Generator(state: 2)
        let seed = Data("0.0.0.0 ads.example.com\n127.0.0.1 tracker.example.net # x\n:: a.b\nplain.example.org\n".utf8)
        for round in 0..<2_000 {
            let input = round % 3 == 0 ? randomBytes(Int.random(in: 0...400, using: &rng), &rng) : mutate(seed, &rng)
            for domain in HostsListParser.parse(input).domains {
                #expect(DomainPattern(domain) != nil, "accepted \(domain.debugDescription)")
                #expect(!domain.contains(where: { $0.isWhitespace || $0 == "#" }))
            }
        }
    }

    @Test func databasesRejectOrParseGarbage() {
        var rng = Generator(state: 3)
        let country = Data("1.0.0.0,1.0.0.255,AU\n2001:db8::,2001:db8::ff,CN\n".utf8)
        let asn = Data("192.0.2.0,192.0.2.255,64496,\"Example, Inc.\"\n".utf8)
        for round in 0..<2_000 {
            let input = round % 3 == 0 ? randomBytes(Int.random(in: 0...300, using: &rng), &rng)
                                       : mutate(round % 2 == 0 ? country : asn, &rng)
            if let db = try? GeoIPDatabase(csv: input) {
                _ = db.country(for: IPAddress("1.0.0.1")!)
                _ = db.networks(for: "AU")
            }
            if let db = try? ASNDatabase(csv: input), let owner = db.owner(for: IPAddress("192.0.2.1")!) {
                #expect(!owner.name.unicodeScalars.contains { $0.properties.generalCategory == .control })
            }
        }
    }

    @Test func blocklistsAndToolOutputParseSafely() {
        var rng = Generator(state: 4)
        let blocklist = Data(#"{"rules":[{"pattern":"a.example.com"}],"blockedCountries":["KP"],"hostsLists":["easyprivacy"]}"#.utf8)
        let btm = Data("Records for UID 501 : x\n #1:\n UUID: 1\n Name: Foo\n Type: login item\n URL: file:///Applications/Foo.app/\n".utf8)
        for round in 0..<2_000 {
            let input = round % 2 == 0 ? mutate(blocklist, &rng) : mutate(btm, &rng)
            if let decoded = try? JSONDecoder.hector.decode(Blocklist.self, from: input) {
                _ = try? HelperLimits.validate(decoded)
            }
            _ = PersistenceParsers.backgroundTaskItems(String(decoding: input, as: UTF8.self))
        }
    }
}
