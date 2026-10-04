import Foundation
import Testing
@testable import HectorCore

@Suite struct DNSMessageTests {
    /// `dig example.com` as sent on the wire: RD and AD set, one question, an EDNS record with a
    /// client cookie.
    static let digQuery: [UInt8] = [
        0x12, 0x34, 0x01, 0x20, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x03, 0x63, 0x6F, 0x6D, 0x00, 0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x29, 0x04, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C,
        0x00, 0x0A, 0x00, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]

    /// An answer to it: a CNAME to `www.example.net`, then an A record for that name, both
    /// compressed against the question.
    static let compressedAnswer: [UInt8] = [
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x03, 0x63, 0x6F, 0x6D, 0x00, 0x00, 0x01, 0x00, 0x01,
        // example.com CNAME www.example.net: owner is a pointer to 12, the target spells "www",
        // "example" again as a pointer to 12 is not possible (it ends in com), so in full.
        0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x0E, 0x10, 0x00, 0x11,
        0x03, 0x77, 0x77, 0x77, 0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x03, 0x6E, 0x65, 0x74, 0x00,
        // www.example.net A 93.184.215.14: owner is a pointer to the CNAME target at offset 41.
        0xC0, 0x29, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x0E, 0x10, 0x00, 0x04, 0x5D, 0xB8, 0xD7, 0x0E,
    ]

    @Test func parsesARealQuery() throws {
        let query = try DNSMessage(bytes: Self.digQuery)
        #expect(query.header.id == 0x1234)
        #expect(!query.header.isResponse)
        #expect(query.header.recursionDesired)
        #expect(query.header.opcode == 0)
        #expect(query.onlyQuestion == DNSQuestion(name: DNSName("example.com")!, type: DNSType.a))
        #expect(query.ednsRecord?.recordClass == 1_232)
        #expect(query.ednsRecord?.data == .raw([0x00, 0x0A, 0x00, 0x08, 1, 2, 3, 4, 5, 6, 7, 8]))
    }

    @Test func followsCompressionPointers() throws {
        let answer = try DNSMessage(bytes: Self.compressedAnswer)
        #expect(answer.answers.count == 2)
        #expect(answer.answers[0].name.text == "example.com")
        #expect(answer.answers[0].data == .name(DNSName("www.example.net")!))
        #expect(answer.answers[1].name.text == "www.example.net")
        #expect(answer.answers[1].data == .a(0x5DB8_D70E))
        #expect(answer.answers[1].ttl == 3_600)
        #expect(answer.isResponse(to: try DNSMessage(bytes: Self.digQuery)))
    }

    @Test func refusesPointersThatDoNotGoBackwards() {
        var header: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        // A pointer to itself, to after itself, and two names pointing at each other.
        let selfPointer = header + [0xC0, 0x0C, 0, 1, 0, 1]
        let forward = header + [0xC0, 0x0E, 0x01, 0x61, 0x00, 0, 1, 0, 1]
        #expect(throws: DNSParseError.badPointer) { try DNSMessage(bytes: selfPointer) }
        #expect(throws: DNSParseError.badPointer) { try DNSMessage(bytes: forward) }

        header[5] = 2
        // Question 1 at 12: "a" then a pointer to question 2's name at 20; question 2 points back
        // to 12. The first pointer already goes forward.
        let loop = header + [0x01, 0x61, 0xC0, 0x14, 0, 1, 0, 1, 0xC0, 0x0C, 0, 1, 0, 1]
        #expect(throws: DNSParseError.badPointer) { try DNSMessage(bytes: loop) }

        // A label sequence that jumps back into itself: "a" at 12, then a pointer to 12.
        let backLoop = Array(header.prefix(5)) + [1] + Array(header.suffix(6)) + [0x01, 0x61, 0xC0, 0x0C, 0, 1, 0, 1]
        #expect(throws: DNSParseError.badPointer) { try DNSMessage(bytes: backLoop) }
    }

    @Test func refusesReservedLabelTypesAndLongNames() {
        let header: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(throws: DNSParseError.badLabel) { try DNSMessage(bytes: header + [0x41, 0x61, 0x00, 0, 1, 0, 1]) }
        #expect(throws: DNSParseError.badLabel) { try DNSMessage(bytes: header + [0x80, 0x00, 0, 1, 0, 1]) }

        // Five labels of 63 bytes: 321 bytes, over the 255 limit.
        var long = header
        for _ in 0..<5 { long += [63] + Array(repeating: 0x61, count: 63) }
        long += [0, 0, 1, 0, 1]
        #expect(throws: DNSParseError.nameTooLong) { try DNSMessage(bytes: long) }

        // Exactly 255 bytes is fine: three labels of 63, one of 61, and the root.
        var limit = header
        for _ in 0..<3 { limit += [63] + Array(repeating: 0x61, count: 63) }
        limit += [61] + Array(repeating: 0x62, count: 61) + [0, 0, 1, 0, 1]
        #expect(throws: Never.self) { try DNSMessage(bytes: limit) }
    }

    @Test func refusesEveryTruncationAndTrailingBytes() {
        for length in 0..<Self.compressedAnswer.count {
            #expect(throws: DNSParseError.self) { try DNSMessage(bytes: Array(Self.compressedAnswer.prefix(length))) }
        }
        #expect(throws: DNSParseError.trailingBytes) { try DNSMessage(bytes: Self.digQuery + [0]) }
        #expect(throws: DNSParseError.tooLarge) { try DNSMessage(bytes: [UInt8](repeating: 0, count: 65_536)) }
    }

    @Test func refusesRecordDataOfTheWrongLength() {
        var bytes = Self.compressedAnswer
        bytes[bytes.count - 5] = 5  // the A record claims 5 bytes of data
        bytes.append(0)
        #expect(throws: DNSParseError.badRecordData) { try DNSMessage(bytes: bytes) }
    }

    @Test func doesNotTrustCountsInTheHeader() {
        // 65,535 questions announced, none present.
        let bytes: [UInt8] = [0, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(throws: DNSParseError.truncated) { try DNSMessage(bytes: bytes) }
    }

    @Test func encodesWhatItParses() throws {
        let answer = try DNSMessage(bytes: Self.compressedAnswer)
        let encoded = try #require(answer.encoded())
        #expect(encoded == Self.compressedAnswer)
        #expect(try DNSMessage(bytes: encoded) == answer)
    }

    @Test func matchesAnswersToQueries() throws {
        let query = try DNSMessage(bytes: Self.digQuery)
        var answer = try DNSMessage(bytes: Self.compressedAnswer)
        #expect(answer.isResponse(to: query))

        answer.questions[0].name = DNSName("EXAMPLE.com")!
        #expect(answer.isResponse(to: query), "names compare without case")

        var other = answer
        other.header.id = 0x4321
        #expect(!other.isResponse(to: query))
        other = answer
        other.questions[0].type = DNSType.aaaa
        #expect(!other.isResponse(to: query))
        other = answer
        other.questions[0].name = DNSName("example.org")!
        #expect(!other.isResponse(to: query))
        other = answer
        other.header.isResponse = false
        #expect(!other.isResponse(to: query))
    }
}

@Suite struct DNSNameTests {
    @Test func givesTextOnlyForHostNames() {
        #expect(DNSName("Ads.Example.COM.")?.text == "ads.example.com")
        #expect(DNSName("_dmarc.example.com")?.text == "_dmarc.example.com")
        #expect(DNSName.root.text == nil)
        #expect(DNSName(labels: [Array("a b".utf8), Array("com".utf8)])?.text == nil)
        #expect(DNSName(labels: [Array("a.b".utf8), Array("com".utf8)])?.text == nil)
        #expect(DNSName(labels: [[0xC3, 0xA9], Array("com".utf8)])?.text == nil)
    }

    @Test func escapesUnprintableBytesForLogs() {
        let name = DNSName(labels: [Array("a.b".utf8), [0x0A, 0x41], Array("com".utf8)])
        #expect(name?.description == "a\\046b.\\010A.com")
        #expect(DNSName.root.description == ".")
    }

    @Test func refusesInvalidLabels() {
        #expect(DNSName("a..b") == nil)
        #expect(DNSName(String(repeating: "a", count: 64) + ".com") == nil)
        #expect(DNSName(labels: [[]]) == nil)
        #expect(DNSName(Array(repeating: "abcdefg", count: 32).joined(separator: ".")) == nil)  // 257 bytes
    }

    @Test func comparesWithoutCase() {
        #expect(DNSName("WWW.Example.com")!.equalsIgnoringCase(DNSName("www.example.COM")!))
        #expect(!DNSName("www.example.com")!.equalsIgnoringCase(DNSName("www.example.co")!))
        #expect(!DNSName("a.example.com")!.equalsIgnoringCase(DNSName("example.com")!))
    }
}

@Suite struct DNSAnswersTests {
    static func query(_ name: String, type: UInt16, edns: Bool = false, id: UInt16 = 7) -> DNSMessage {
        var header = DNSHeader(id: id, flags: 0)
        header.recursionDesired = true
        let opt = DNSResourceRecord(name: .root, type: DNSType.opt, recordClass: 4_096, ttl: 0, data: .raw([]))
        return DNSMessage(header: header, questions: [DNSQuestion(name: DNSName(name)!, type: type)],
                          additionals: edns ? [opt] : [])
    }

    @Test func answersBlockedAddressesWithTheNullAddress() throws {
        let query = Self.query("ads.example.com", type: DNSType.a)
        let answer = try DNSMessage(bytes: try #require(DNSAnswers.blocked(query, style: .nullAddress, ttl: 2)))
        #expect(answer.isResponse(to: query))
        #expect(answer.header.responseCode == DNSResponseCode.noError)
        #expect(answer.header.recursionDesired && answer.header.recursionAvailable)
        #expect(answer.answers == [DNSResourceRecord(name: DNSName("ads.example.com")!, type: DNSType.a, ttl: 2, data: .a(0))])

        let six = Self.query("ads.example.com", type: DNSType.aaaa)
        let sixAnswer = try DNSMessage(bytes: try #require(DNSAnswers.blocked(six, style: .nullAddress, ttl: 2)))
        #expect(sixAnswer.answers.map(\.data) == [.aaaa(0)])
    }

    @Test func answersOtherTypesWithNoData() throws {
        for type in [DNSType.https, DNSType.svcb, DNSType.mx, DNSType.txt, DNSType.any] {
            let query = Self.query("ads.example.com", type: type)
            let answer = try DNSMessage(bytes: try #require(DNSAnswers.blocked(query, style: .nullAddress, ttl: 2)))
            #expect(answer.header.responseCode == DNSResponseCode.noError)
            #expect(answer.answers.isEmpty)
        }
    }

    @Test func answersNXDOMAINInThatStyle() throws {
        let query = Self.query("ads.example.com", type: DNSType.a, edns: true)
        let answer = try DNSMessage(bytes: try #require(DNSAnswers.blocked(query, style: .nameError, ttl: 2)))
        #expect(answer.header.responseCode == DNSResponseCode.nameError)
        #expect(answer.answers.isEmpty)
        // EDNS in, EDNS out, with Hector's own payload size.
        #expect(answer.ednsRecord?.recordClass == DNSAnswers.ednsPayloadSize)
    }

    @Test func compressesTheAnswerAgainstTheQuestion() throws {
        let query = Self.query("ads.example.com", type: DNSType.a)
        let bytes = try #require(DNSAnswers.blocked(query, style: .nullAddress, ttl: 2))
        // Header, the question (17 + 4), then the answer's owner as a pointer to offset 12.
        #expect(bytes.count == 12 + 21 + 2 + 10 + 4)
        #expect(bytes[33] == 0xC0 && bytes[34] == 0x0C)
    }

    @Test func answersOnlyStandardQueries() {
        var response = Self.query("ads.example.com", type: DNSType.a)
        response.header.isResponse = true
        #expect(DNSAnswers.blocked(response, style: .nullAddress, ttl: 2) == nil)

        var notify = Self.query("ads.example.com", type: DNSType.a)
        notify.header.flags |= 4 << 11
        #expect(DNSAnswers.blocked(notify, style: .nullAddress, ttl: 2) == nil)

        var two = Self.query("ads.example.com", type: DNSType.a)
        two.questions.append(two.questions[0])
        #expect(DNSAnswers.blocked(two, style: .nullAddress, ttl: 2) == nil)
    }

    @Test func reportsFailuresAndFormatErrors() throws {
        let query = Self.query("example.com", type: DNSType.a, id: 99)
        let failure = try DNSMessage(bytes: try #require(DNSAnswers.failure(query, code: DNSResponseCode.serverFailure)))
        #expect(failure.header.responseCode == DNSResponseCode.serverFailure)
        #expect(failure.isResponse(to: query))

        let garbage: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0xFF]
        let formErr = try DNSMessage(bytes: try #require(DNSAnswers.formatError(forUnparsable: garbage)))
        #expect(formErr.header.id == 0xABCD)
        #expect(formErr.header.isResponse)
        #expect(formErr.header.responseCode == DNSResponseCode.formatError)
        #expect(formErr.questions.isEmpty)

        #expect(DNSAnswers.formatError(forUnparsable: [0xAB, 0xCD]) == nil)
        var responseBytes = garbage
        responseBytes[2] |= 0x80
        #expect(DNSAnswers.formatError(forUnparsable: responseBytes) == nil, "never answer a response")
    }
}
