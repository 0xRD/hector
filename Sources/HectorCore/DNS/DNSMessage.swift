import Foundation

/// A domain name as it travels in a DNS message: a list of labels, each 1 to 63 bytes.
///
/// Labels are kept as raw bytes: on the wire a label may hold any byte, dots and spaces included.
/// `text` gives the lowercased dotted form only for names made of letters, digits, `-` and `_`,
/// the only names a blocklist can hold; any other name never matches a rule.
public struct DNSName: Hashable, Sendable {
    public let labels: [[UInt8]]

    /// The longest name allowed on the wire, length bytes and final zero included (RFC 1035).
    public static let maximumWireLength = 255
    public static let maximumLabelLength = 63

    /// The root name (`.`).
    public static let root = DNSName(validatedLabels: [])

    private init(validatedLabels: [[UInt8]]) {
        labels = validatedLabels
    }

    /// `nil` when a label is empty or too long, or the whole name is too long.
    public init?(labels: [[UInt8]]) {
        var length = 1
        for label in labels {
            guard (1...Self.maximumLabelLength).contains(label.count) else { return nil }
            length += label.count + 1
        }
        guard length <= Self.maximumWireLength else { return nil }
        self.labels = labels
    }

    /// Parses a dotted name (`"ads.example.com"`, an optional trailing dot). Every byte of a label
    /// is taken as is: no escapes.
    public init?(_ text: String) {
        if text == "." || text.isEmpty {
            self = .root
            return
        }
        let body = text.hasSuffix(".") ? text.dropLast() : text[...]
        self.init(labels: body.split(separator: ".", omittingEmptySubsequences: false).map { Array($0.utf8) })
    }

    /// Bytes this name takes on the wire without compression.
    public var wireLength: Int {
        labels.reduce(1) { $0 + $1.count + 1 }
    }

    /// The lowercased dotted form without a trailing dot, or `nil` when a label holds a byte other
    /// than a letter, a digit, `-` or `_` (and for the root, which no rule can name).
    public var text: String? {
        guard !labels.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(wireLength)
        for label in labels {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: ".")) }
            for byte in label {
                guard let lowered = Self.hostByte(byte) else { return nil }
                bytes.append(lowered)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The lowercase form of a byte allowed in a host name, or `nil`.
    private static func hostByte(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 65...90: return byte + 32  // A–Z
        case 97...122, 48...57, 45, 95: return byte  // a–z, 0–9, -, _
        default: return nil
        }
    }

    /// Names compare without regard to ASCII case (RFC 4343).
    public func equalsIgnoringCase(_ other: DNSName) -> Bool {
        guard labels.count == other.labels.count else { return false }
        for (left, right) in zip(labels, other.labels) {
            guard left.count == right.count else { return false }
            for (a, b) in zip(left, right) where Self.asciiLower(a) != Self.asciiLower(b) {
                return false
            }
        }
        return true
    }

    static func asciiLower(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}

extension DNSName: CustomStringConvertible {
    /// For logs: bytes outside printable ASCII and dots inside labels are escaped (`\046`).
    public var description: String {
        guard !labels.isEmpty else { return "." }
        return labels.map { label in
            label.map { byte -> String in
                if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "\\") || !(33...126).contains(byte) {
                    let digits = String(byte)
                    return "\\" + String(repeating: "0", count: 3 - digits.count) + digits
                }
                return String(UnicodeScalar(byte))
            }.joined()
        }.joined(separator: ".")
    }
}

/// Record types Hector reads or writes.
public enum DNSType {
    public static let a: UInt16 = 1
    public static let ns: UInt16 = 2
    public static let cname: UInt16 = 5
    public static let soa: UInt16 = 6
    public static let ptr: UInt16 = 12
    public static let mx: UInt16 = 15
    public static let txt: UInt16 = 16
    public static let aaaa: UInt16 = 28
    public static let srv: UInt16 = 33
    public static let dname: UInt16 = 39
    public static let opt: UInt16 = 41
    public static let svcb: UInt16 = 64
    public static let https: UInt16 = 65
    public static let any: UInt16 = 255
}

/// Response codes (RCODE, the low 4 bits of the flags).
public enum DNSResponseCode {
    public static let noError: UInt8 = 0
    public static let formatError: UInt8 = 1
    public static let serverFailure: UInt8 = 2
    public static let nameError: UInt8 = 3  // NXDOMAIN
    public static let notImplemented: UInt8 = 4
    public static let refused: UInt8 = 5
}

/// The fixed 12-byte header of a DNS message (RFC 1035 §4.1.1).
public struct DNSHeader: Hashable, Sendable {
    public var id: UInt16
    /// QR, opcode, AA, TC, RD, RA, Z, AD, CD and RCODE, as on the wire.
    public var flags: UInt16

    public static let length = 12

    public init(id: UInt16, flags: UInt16) {
        self.id = id
        self.flags = flags
    }

    public var isResponse: Bool {
        get { flags & 0x8000 != 0 }
        set { setFlag(0x8000, newValue) }
    }

    public var opcode: UInt8 { UInt8((flags >> 11) & 0x0F) }

    public var isTruncated: Bool {
        get { flags & 0x0200 != 0 }
        set { setFlag(0x0200, newValue) }
    }

    public var recursionDesired: Bool {
        get { flags & 0x0100 != 0 }
        set { setFlag(0x0100, newValue) }
    }

    public var recursionAvailable: Bool {
        get { flags & 0x0080 != 0 }
        set { setFlag(0x0080, newValue) }
    }

    public var checkingDisabled: Bool { flags & 0x0010 != 0 }

    public var responseCode: UInt8 {
        get { UInt8(flags & 0x000F) }
        set { flags = (flags & 0xFFF0) | UInt16(newValue & 0x0F) }
    }

    private mutating func setFlag(_ bit: UInt16, _ on: Bool) {
        flags = on ? flags | bit : flags & ~bit
    }
}

public struct DNSQuestion: Hashable, Sendable {
    public var name: DNSName
    public var type: UInt16
    public var recordClass: UInt16

    public static let internetClass: UInt16 = 1

    public init(name: DNSName, type: UInt16, recordClass: UInt16 = DNSQuestion.internetClass) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
    }
}

/// The data of a resource record.
///
/// Only types without names inside, and the four types whose data is exactly one name, are
/// decoded. Anything else stays raw. Raw data that holds a compressed name (MX, SOA, SRV…) only
/// makes sense inside the message it came from: Hector forwards such answers as the bytes it
/// received and never re-encodes them.
public enum DNSRecordData: Hashable, Sendable {
    case a(UInt32)
    case aaaa(UInt128)
    /// CNAME, NS, PTR and DNAME.
    case name(DNSName)
    case raw([UInt8])
}

public struct DNSResourceRecord: Hashable, Sendable {
    public var name: DNSName
    public var type: UInt16
    /// For OPT records, the sender's UDP payload size.
    public var recordClass: UInt16
    /// For OPT records, the extended RCODE and flags.
    public var ttl: UInt32
    public var data: DNSRecordData

    public init(name: DNSName, type: UInt16, recordClass: UInt16 = DNSQuestion.internetClass, ttl: UInt32, data: DNSRecordData) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
        self.ttl = ttl
        self.data = data
    }
}

/// Why bytes were refused as a DNS message.
public enum DNSParseError: Error, Equatable, Sendable {
    case truncated
    case tooLarge
    case badLabel
    case nameTooLong
    /// A compression pointer that does not point strictly backwards, or too many of them.
    case badPointer
    case badRecordData
    /// Bytes after the last section the header announced.
    case trailingBytes
}

/// A DNS message (RFC 1035): header, question, answer, authority and additional sections.
///
/// `init(bytes:)` is a strict parser meant for bytes from anyone on this Mac (queries to the local
/// resolver) or from the network (upstream answers): every read is bounds-checked, a compression
/// pointer must point strictly before the name that holds it (so pointers cannot loop), names
/// longer than 255 bytes and labels of the two reserved kinds are refused, and so are bytes after
/// the last record. Counts in the header are never trusted for allocation.
public struct DNSMessage: Hashable, Sendable {
    public var header: DNSHeader
    public var questions: [DNSQuestion]
    public var answers: [DNSResourceRecord]
    public var authorities: [DNSResourceRecord]
    public var additionals: [DNSResourceRecord]

    /// The largest message DNS can carry (over TCP, a 16-bit length).
    public static let maximumLength = 65_535

    public init(header: DNSHeader, questions: [DNSQuestion] = [], answers: [DNSResourceRecord] = [],
                authorities: [DNSResourceRecord] = [], additionals: [DNSResourceRecord] = []) {
        self.header = header
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additionals = additionals
    }

    public init(bytes: Data) throws {
        try self.init(bytes: [UInt8](bytes))
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count <= Self.maximumLength else { throw DNSParseError.tooLarge }
        var reader = DNSReader(bytes: bytes)
        let id = try reader.uint16()
        let flags = try reader.uint16()
        let questionCount = try reader.uint16()
        let answerCount = try reader.uint16()
        let authorityCount = try reader.uint16()
        let additionalCount = try reader.uint16()
        header = DNSHeader(id: id, flags: flags)

        questions = []
        for _ in 0..<questionCount {
            let name = try reader.name()
            questions.append(DNSQuestion(name: name, type: try reader.uint16(), recordClass: try reader.uint16()))
        }
        answers = try reader.records(answerCount)
        authorities = try reader.records(authorityCount)
        additionals = try reader.records(additionalCount)
        guard reader.isAtEnd else { throw DNSParseError.trailingBytes }
    }

    /// The single question of a query, the only shape the resolver answers itself.
    public var onlyQuestion: DNSQuestion? {
        questions.count == 1 ? questions[0] : nil
    }

    /// The EDNS record (OPT, RFC 6891), if the message has one.
    public var ednsRecord: DNSResourceRecord? {
        additionals.first { $0.type == DNSType.opt }
    }

    /// Whether `self` can be the upstream answer to `query`: same ID, a response, same opcode and
    /// the same question (names without regard to case). Checked before an answer is forwarded,
    /// against spoofed or stray packets.
    public func isResponse(to query: DNSMessage) -> Bool {
        guard header.isResponse, header.id == query.header.id, header.opcode == query.header.opcode,
              questions.count == query.questions.count else { return false }
        for (mine, theirs) in zip(questions, query.questions) {
            guard mine.type == theirs.type, mine.recordClass == theirs.recordClass,
                  mine.name.equalsIgnoringCase(theirs.name) else { return false }
        }
        return true
    }

    /// The wire form. Owner names are compressed against names already written; record data is
    /// written as decoded (see `DNSRecordData`). Messages built by Hector stay far below the size
    /// limit; `nil` if one did not.
    public func encoded() -> [UInt8]? {
        let counts = [questions.count, answers.count, authorities.count, additionals.count]
        guard counts.allSatisfy({ $0 <= Int(UInt16.max) }) else { return nil }
        var writer = DNSWriter()
        writer.uint16(header.id)
        writer.uint16(header.flags)
        for count in counts { writer.uint16(UInt16(count)) }
        for question in questions {
            writer.name(question.name)
            writer.uint16(question.type)
            writer.uint16(question.recordClass)
        }
        for record in answers + authorities + additionals {
            guard writer.record(record) else { return nil }
        }
        guard writer.bytes.count <= Self.maximumLength else { return nil }
        return writer.bytes
    }
}

// MARK: - Reading

/// A bounds-checked cursor over a message.
struct DNSReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    /// Pointers only go backwards, so a name can follow at most one per earlier byte; this caps
    /// the work on a hostile message much lower.
    static let maximumPointers = 64

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func uint8() throws -> UInt8 {
        guard offset < bytes.count else { throw DNSParseError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() throws -> UInt16 {
        guard bytes.count - offset >= 2 else { throw DNSParseError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func uint32() throws -> UInt32 {
        let high = UInt32(try uint16())
        let low = UInt32(try uint16())
        return high << 16 | low
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, bytes.count - offset >= count else { throw DNSParseError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    /// Reads a name at the cursor, following compression pointers. The cursor ends after the name
    /// as written here (after the first pointer, if any).
    mutating func name() throws -> DNSName {
        var labels: [[UInt8]] = []
        var length = 1
        var position = offset
        // Every pointer must land strictly before the label sequence that holds it.
        var lowestStart = offset
        var resumeAt: Int?
        var pointers = 0

        while true {
            guard position < bytes.count else { throw DNSParseError.truncated }
            let byte = bytes[position]
            switch byte & 0xC0 {
            case 0x00:
                let count = Int(byte)
                if count == 0 {
                    offset = resumeAt ?? position + 1
                    guard let name = DNSName(labels: labels) else { throw DNSParseError.nameTooLong }
                    return name
                }
                guard bytes.count - (position + 1) >= count else { throw DNSParseError.truncated }
                length += count + 1
                guard length <= DNSName.maximumWireLength else { throw DNSParseError.nameTooLong }
                labels.append(Array(bytes[(position + 1)...(position + count)]))
                position += count + 1
            case 0xC0:
                guard bytes.count - position >= 2 else { throw DNSParseError.truncated }
                let target = Int(byte & 0x3F) << 8 | Int(bytes[position + 1])
                pointers += 1
                guard target < lowestStart, pointers <= Self.maximumPointers else { throw DNSParseError.badPointer }
                if resumeAt == nil { resumeAt = position + 2 }
                lowestStart = target
                position = target
            default:
                // 0x40 (extended label, RFC 6891 deprecated it) and 0x80 are not names.
                throw DNSParseError.badLabel
            }
        }
    }

    mutating func records(_ count: UInt16) throws -> [DNSResourceRecord] {
        var records: [DNSResourceRecord] = []
        for _ in 0..<count {
            records.append(try record())
        }
        return records
    }

    private mutating func record() throws -> DNSResourceRecord {
        let owner = try name()
        let type = try uint16()
        let recordClass = try uint16()
        let ttl = try uint32()
        let length = Int(try uint16())
        guard bytes.count - offset >= length else { throw DNSParseError.truncated }
        let end = offset + length
        let data: DNSRecordData
        switch type {
        case DNSType.a where recordClass == DNSQuestion.internetClass:
            guard length == 4 else { throw DNSParseError.badRecordData }
            data = .a(try uint32())
        case DNSType.aaaa where recordClass == DNSQuestion.internetClass:
            guard length == 16 else { throw DNSParseError.badRecordData }
            var value: UInt128 = 0
            for byte in try take(16) { value = value << 8 | UInt128(byte) }
            data = .aaaa(value)
        case DNSType.cname, DNSType.ns, DNSType.ptr, DNSType.dname:
            let target = try name()
            // The name, compressed or not, must fill the data exactly.
            guard offset == end else { throw DNSParseError.badRecordData }
            data = .name(target)
        default:
            data = .raw(try take(length))
        }
        return DNSResourceRecord(name: owner, type: type, recordClass: recordClass, ttl: ttl, data: data)
    }
}

// MARK: - Writing

/// Builds a message, compressing owner names and decoded data names against earlier ones.
struct DNSWriter {
    private(set) var bytes: [UInt8] = []
    /// Offsets of the name suffixes already written, keyed by their lowercased labels.
    private var suffixes: [[[UInt8]]: Int] = [:]

    mutating func uint16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func uint32(_ value: UInt32) {
        uint16(UInt16(value >> 16))
        uint16(UInt16(value & 0xFFFF))
    }

    mutating func name(_ name: DNSName) {
        let lowered = name.labels.map { $0.map(DNSName.asciiLower) }
        for index in lowered.indices {
            let suffix = Array(lowered[index...])
            if let target = suffixes[suffix] {
                uint16(0xC000 | UInt16(target))
                return
            }
            // A pointer holds 14 bits: later names can only point into the first 16 KB.
            if bytes.count < 0x4000 { suffixes[suffix] = bytes.count }
            let label = name.labels[index]
            bytes.append(UInt8(label.count))
            bytes.append(contentsOf: label)
        }
        bytes.append(0)
    }

    /// `false` when the data does not fit in a record (more than 65,535 bytes).
    mutating func record(_ record: DNSResourceRecord) -> Bool {
        name(record.name)
        uint16(record.type)
        uint16(record.recordClass)
        uint32(record.ttl)
        let lengthAt = bytes.count
        uint16(0)
        switch record.data {
        case .a(let value):
            uint32(value)
        case .aaaa(let value):
            for shift in stride(from: 120, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt128(shift)))
            }
        case .name(let target):
            name(target)
        case .raw(let data):
            bytes.append(contentsOf: data)
        }
        let length = bytes.count - lengthAt - 2
        guard length <= Int(UInt16.max) else { return false }
        bytes[lengthAt] = UInt8(length >> 8)
        bytes[lengthAt + 1] = UInt8(length & 0xFF)
        return true
    }
}
