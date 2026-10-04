import Foundation
import Testing
@testable import HectorCore

/// Random and mutated inputs for the local resolver's parsers: DNS messages (anyone on this Mac
/// can send one to 127.0.0.1:53, and upstream answers come from the network) and Adblock-style
/// lists. None may crash, and whatever they accept must still be valid. Seeded, like `FuzzTests`.
@Suite struct DNSFuzzTests {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var x = state
            x ^= x >> 33
            return x
        }
    }

    /// Bytes that matter to DNS: label lengths, pointer bytes, zero, the record types used here.
    private static let interesting: [UInt8] = [0x00, 0x01, 0x03, 0x05, 0x0C, 0x1C, 0x29, 0x3F, 0x40, 0x41, 0x80, 0xC0, 0xC1, 0xFF, 0x61, 0x2E]
    private static let listAlphabet = Array("abcxyz019.-_|^@$!#*/:[] \n\r\té😀".utf8)

    private func mutate(_ bytes: [UInt8], alphabet: [UInt8], _ rng: inout Generator) -> [UInt8] {
        var bytes = bytes
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            guard !bytes.isEmpty else { break }
            let index = Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0...4, using: &rng) {
            case 0: bytes[index] = UInt8.random(in: 0...255, using: &rng)
            case 1: bytes.remove(at: index)
            case 2: bytes.insert(alphabet.randomElement(using: &rng)!, at: index)
            case 3: bytes[index] = alphabet.randomElement(using: &rng)!
            default: bytes.insert(contentsOf: bytes[index..<min(bytes.count, index + 12)], at: index)
            }
        }
        return bytes
    }

    private func randomBytes(_ count: Int, _ rng: inout Generator) -> [UInt8] {
        (0..<count).map { _ in
            Bool.random(using: &rng) ? Self.interesting.randomElement(using: &rng)! : UInt8.random(in: 0...255, using: &rng)
        }
    }

    @Test func messagesParseSafely() throws {
        var rng = Generator(state: 11)
        let blocked = DNSAnswers.blocked(DNSAnswersTests.query("ads.example.com", type: DNSType.aaaa, edns: true),
                                         style: .nullAddress, ttl: 2)!
        let seeds = [DNSMessageTests.digQuery, DNSMessageTests.compressedAnswer, blocked]
        var parsed = 0
        for round in 0..<20_000 {
            let input = round % 5 == 0 ? randomBytes(Int.random(in: 0...120, using: &rng), &rng)
                                       : mutate(seeds.randomElement(using: &rng)!, alphabet: Self.interesting, &rng)
            guard let message = try? DNSMessage(bytes: input) else {
                // What does not parse gets at most a bare FORMERR, which must itself parse.
                if let reply = DNSAnswers.formatError(forUnparsable: input) {
                    #expect((try? DNSMessage(bytes: reply))?.header.responseCode == DNSResponseCode.formatError)
                }
                continue
            }
            parsed += 1
            for name in message.questions.map(\.name) + message.answers.map(\.name) {
                #expect(name.wireLength <= DNSName.maximumWireLength)
                #expect(name.labels.allSatisfy { (1...63).contains($0.count) })
                if let text = name.text {
                    // Only what a rule can hold: lowercase letters, digits, `-`, `_` and dots.
                    #expect(text.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 })
                }
                _ = name.description
            }
            // Re-encoding never crashes, and the result parses again with the same questions.
            if let encoded = message.encoded() {
                let again = try DNSMessage(bytes: encoded)
                #expect(again.questions.count == message.questions.count)
                for (left, right) in zip(again.questions, message.questions) {
                    #expect(left.name.equalsIgnoringCase(right.name) && left.type == right.type)
                }
            }
            // A blocked answer to anything that looks like a query is a valid answer to it.
            for style in DNSBlockStyle.allCases {
                if let reply = DNSAnswers.blocked(message, style: style, ttl: 2) {
                    #expect(try DNSMessage(bytes: reply).isResponse(to: message))
                }
            }
        }
        // The mutations must reach past the first checks, or the test proves little.
        #expect(parsed > 1_000)
    }

    @Test func adblockListsOnlyYieldValidDomains() {
        var rng = Generator(state: 12)
        let seed = Array("[Adblock Plus]\n! c\n||ads.example.com^\n@@||ok.example.com^$important\n||x.example.net^$badfilter\n".utf8)
        for _ in 0..<3_000 {
            let input = Data(mutate(seed, alphabet: Self.listAlphabet, &rng))
            let result = DomainListFormat.adblock.parse(input)
            for domain in result.subtrees + result.exceptions {
                #expect(DomainPattern(domain) != nil, "accepted \(domain.debugDescription)")
                #expect(!HostsListParser.isReserved(domain))
            }
        }
    }

    @Test func resolverLogLinesParseSafely() {
        var rng = Generator(state: 14)
        let seeds = [ResolverLogTests.queryRecord, ResolverLogTests.getAddrInfo, ResolverLogTests.networkFramework,
                     ResolverLogTests.question].map { Array($0.utf8) }
        let alphabet = Array("[]()->Q0123456789abcdef,:' <>RSTART".utf8)
        for _ in 0..<5_000 {
            let input = String(decoding: mutate(seeds.randomElement(using: &rng)!, alphabet: alphabet, &rng), as: UTF8.self)
            if case .request(_, let client, _, _)? = MDNSResponderLog.event(fromMessage: input) {
                #expect(client.pid > 0)
                #expect(client.name.count <= 64)
                #expect(!client.name.unicodeScalars.contains { $0.properties.generalCategory == .control })
            }
        }
    }

    @Test func domainSetsAgreeWithAModel() {
        var rng = Generator(state: 13)
        let labels = ["a", "b", "ads", "x-y", "com", "net", "example"]
        func randomName() -> String {
            (0..<Int.random(in: 1...4, using: &rng)).map { _ in labels.randomElement(using: &rng)! }.joined(separator: ".")
        }
        for _ in 0..<200 {
            let exact = Set((0..<Int.random(in: 0...20, using: &rng)).map { _ in randomName() })
            let subtrees = Set((0..<Int.random(in: 0...20, using: &rng)).map { _ in randomName() })
            let set = DomainSet(exact: exact, subtrees: subtrees)
            for _ in 0..<50 {
                let name = randomName()
                let parts = name.split(separator: ".")
                let parents = (1..<max(parts.count, 1)).map { parts[$0...].joined(separator: ".") }
                let expected = exact.contains(name) || subtrees.contains(name) || parents.contains(where: subtrees.contains)
                #expect(set.contains(name) == expected, "\(name)")
            }
        }
    }
}
