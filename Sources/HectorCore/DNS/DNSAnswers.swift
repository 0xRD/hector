import Foundation

/// How the local resolver answers a name it blocks.
public enum DNSBlockStyle: String, Codable, Sendable, CaseIterable {
    /// `0.0.0.0` for A, `::` for AAAA, an empty answer for every other type. Apps fail at once
    /// (nothing listens there) and nothing is cached as "this name does not exist".
    case nullAddress
    /// NXDOMAIN for every type: the name does not exist.
    case nameError
}

/// Answers the local resolver writes itself, without asking upstream.
///
/// Every answer echoes the query's ID, opcode, question and RD bit, sets RA, and carries an EDNS
/// record when the query had one (RFC 6891), with no options echoed.
public enum DNSAnswers {
    /// UDP payload size Hector announces in EDNS: the size DNS Flag Day 2020 recommends.
    public static let ednsPayloadSize: UInt16 = 1_232

    /// The answer to a query for a blocked name; `nil` unless the query is a standard query
    /// (opcode 0, not a response) with exactly one question.
    public static func blocked(_ query: DNSMessage, style: DNSBlockStyle, ttl: UInt32) -> [UInt8]? {
        guard isStandardQuery(query), let question = query.onlyQuestion else { return nil }
        var answers: [DNSResourceRecord] = []
        var code = DNSResponseCode.noError
        switch style {
        case .nameError:
            code = DNSResponseCode.nameError
        case .nullAddress where question.recordClass == DNSQuestion.internetClass:
            if question.type == DNSType.a {
                answers.append(DNSResourceRecord(name: question.name, type: DNSType.a, ttl: ttl, data: .a(0)))
            } else if question.type == DNSType.aaaa {
                answers.append(DNSResourceRecord(name: question.name, type: DNSType.aaaa, ttl: ttl, data: .aaaa(0)))
            }
        case .nullAddress:
            break
        }
        return response(to: query, code: code, answers: answers)
    }

    /// An answer with no records and `code` (SERVFAIL when upstream cannot be reached, REFUSED,
    /// NOTIMP); `nil` unless the message is a query.
    public static func failure(_ query: DNSMessage, code: UInt8) -> [UInt8]? {
        guard !query.header.isResponse else { return nil }
        return response(to: query, code: code, answers: [])
    }

    /// FORMERR for bytes that did not parse but start with a query header: the header alone, with
    /// the query's ID, and no sections (RFC 1035 allows nothing more since nothing was understood).
    /// `nil` for anything shorter than a header or already a response, which gets no answer.
    public static func formatError(forUnparsable bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= DNSHeader.length, bytes[2] & 0x80 == 0 else { return nil }
        let opcode = (bytes[2] >> 3) & 0x0F
        var header = DNSHeader(id: UInt16(bytes[0]) << 8 | UInt16(bytes[1]), flags: UInt16(opcode) << 11)
        header.isResponse = true
        header.responseCode = DNSResponseCode.formatError
        return DNSMessage(header: header).encoded()
    }

    /// Opcode 0 (QUERY), and a query rather than a response.
    public static func isStandardQuery(_ message: DNSMessage) -> Bool {
        !message.header.isResponse && message.header.opcode == 0
    }

    private static func response(to query: DNSMessage, code: UInt8, answers: [DNSResourceRecord]) -> [UInt8]? {
        var header = DNSHeader(id: query.header.id, flags: UInt16(query.header.opcode) << 11)
        header.isResponse = true
        header.recursionDesired = query.header.recursionDesired
        header.recursionAvailable = true
        header.responseCode = code
        var additionals: [DNSResourceRecord] = []
        if query.ednsRecord != nil {
            additionals.append(DNSResourceRecord(name: .root, type: DNSType.opt, recordClass: ednsPayloadSize, ttl: 0, data: .raw([])))
        }
        let message = DNSMessage(header: header, questions: query.questions, answers: answers, additionals: additionals)
        return message.encoded()
    }
}
