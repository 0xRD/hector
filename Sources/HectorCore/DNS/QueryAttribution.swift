import Foundation

// Which app asked for a name.
//
// Every query the local resolver receives comes from mDNSResponder: apps ask mDNSResponder, and
// mDNSResponder asks the resolver. The query itself carries no app. mDNSResponder's own log does,
// without root (an administrator can read it with `/usr/bin/log`), at the default level:
//
//   [R279367] DNSServiceQueryRecord START -- qname: <mask.hash: '…'>, qtype: AAAA, flags: 0x15000,
//             interface index: 0, client pid: 82079 (dscacheutil), name hash: 818588a2
//   [R279239] DNSServiceGetAddrInfo START -- hostname: <mask.hash: '…'>, protocols: 3, …,
//             client pid: 79461 (curl), name hash: 6fe56adf
//   [R279233] getaddrinfo start -- flags: 0xC000D000, …, hostname: <mask.hash: '…'>, …,
//             client pid: 25514 (OneDrive)
//   [R279233->Q64907] Question assigned DNS service 20
//
// The name itself is masked, but two keys survive:
// - `name hash` is FNV-1a (32 bits) of the lowercased name in wire form, which the resolver can
//   compute for every query it receives (checked on macOS 26.6 against two names). The first two
//   shapes (the dns_sd and getaddrinfo(3) path: command-line tools, BSD sockets) carry it.
// - `Q…` is very likely the 16-bit ID of the DNS message mDNSResponder sends upstream, so the
//   resolver can look up the request (`R…`) and its client by the ID of the query it received.
//   The third shape (Network.framework, used by most apps) only has this key. Not yet checked
//   against a packet capture: see docs/LOCAL_DNS.md.
//
// None of this is an API: the messages may change with macOS, and attribution then falls back to
// "unknown app" without affecting resolution.

extension DNSName {
    /// The `name hash` mDNSResponder logs: FNV-1a 32 over the lowercased wire form (length bytes,
    /// labels, final zero).
    public var mDNSResponderHash: UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        func add(_ byte: UInt8) {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        for label in labels {
            add(UInt8(label.count))
            for byte in label { add(DNSName.asciiLower(byte)) }
        }
        add(0)
        return hash
    }
}

/// One lookup event from mDNSResponder's log.
public enum ResolverLogEvent: Hashable, Sendable {
    /// A client started a lookup. `nameHash` and `type` are known for the dns_sd shapes only;
    /// `type` is `nil` for address lookups (A and AAAA) and unknown mnemonics.
    case request(id: UInt32, client: ResolverClient, nameHash: UInt32?, type: UInt16?)
    /// mDNSResponder created question `queryID` for request `request` and will send it upstream
    /// unless its cache answers.
    case question(request: UInt32, queryID: UInt16)
}

/// The process that asked mDNSResponder. `name` is the short process name as the log prints it
/// (at most 16 characters, chosen by the process itself: a label, never an identity); the PID
/// leads to the executable through the process collector.
public struct ResolverClient: Hashable, Sendable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Reads lookup events from mDNSResponder's log lines (`log stream --style ndjson`).
public enum MDNSResponderLog {
    static let executablePath = "/usr/sbin/mDNSResponder"
    /// For `log stream --predicate`: only the four message shapes above.
    public static let predicate = #"process == "mDNSResponder" AND (eventMessage CONTAINS "client pid:" OR eventMessage CONTAINS "Question assigned")"#

    /// The event in one ndjson line, if mDNSResponder's own executable logged it. Any process can
    /// log under any subsystem or category, so the image path, set by the system, is what counts.
    public static func event(fromLogLine line: Substring) -> ResolverLogEvent? {
        guard line.hasPrefix("{"), line.utf8.count <= 8_192,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["processImagePath"] as? String == executablePath,
              let message = object["eventMessage"] as? String else { return nil }
        return event(fromMessage: message)
    }

    /// The event in one message, or `nil` for any other message.
    public static func event(fromMessage message: String) -> ResolverLogEvent? {
        guard message.hasPrefix("[R"), let close = message.firstIndex(of: "]") else { return nil }
        let tag = message[message.index(message.startIndex, offsetBy: 2)..<close]
        let body = message[message.index(after: close)...].drop(while: { $0 == " " })

        if let arrow = tag.range(of: "->Q") {
            guard body.hasPrefix("Question assigned"), let request = UInt32(tag[..<arrow.lowerBound]),
                  let queryID = UInt16(tag[arrow.upperBound...]) else { return nil }
            return .question(request: request, queryID: queryID)
        }
        guard let request = UInt32(tag) else { return nil }

        let isQueryRecord = body.hasPrefix("DNSServiceQueryRecord START")
        let isAddressLookup = body.hasPrefix("DNSServiceGetAddrInfo START") || body.hasPrefix("getaddrinfo start")
        guard isQueryRecord || isAddressLookup else { return nil }
        // The name must be masked (the default). In clear (private data logging turned on), a
        // name is chosen by the app and may hold ", client pid: 1 (Safari)": such lines are
        // refused, and every field is read after the masked name only.
        guard let mask = body.range(of: "<mask.hash: '"),
              let maskEnd = body[mask.upperBound...].range(of: "'>") else { return nil }
        let fields = body[maskEnd.upperBound...]
        guard let client = client(in: fields) else { return nil }
        let type = isQueryRecord ? field("qtype", in: fields).flatMap(typeNumber) : nil
        let hash = lastField("name hash", in: fields).flatMap { $0.utf8.count == 8 ? UInt32($0, radix: 16) : nil }
        return .request(id: request, client: client, nameHash: hash, type: type)
    }

    /// The value after `, name: ` up to the next comma.
    private static func field(_ name: String, in fields: Substring) -> Substring? {
        guard let range = fields.range(of: ", \(name): ") else { return nil }
        let rest = fields[range.upperBound...]
        return rest[..<(rest.firstIndex(of: ",") ?? rest.endIndex)]
    }

    /// The value after the last `, name: `, to the end: the name hash comes after the process
    /// name, which the process chose.
    private static func lastField(_ name: String, in fields: Substring) -> Substring? {
        guard let range = fields.range(of: ", \(name): ", options: .backwards) else { return nil }
        return fields[range.upperBound...]
    }

    /// `client pid: 82079 (dscacheutil)`. The PID comes first, so the process name cannot fake
    /// it; the name may hold anything, so it runs to the `)` before the last `, name hash: ` or
    /// before the end.
    private static func client(in fields: Substring) -> ResolverClient? {
        guard let range = fields.range(of: ", client pid: ") else { return nil }
        let rest = fields[range.upperBound...]
        guard let space = rest.firstIndex(of: " "), let pid = Int32(rest[..<space]), pid > 0 else { return nil }
        let afterPID = rest[rest.index(after: space)...]
        guard afterPID.hasPrefix("(") else { return nil }
        let end: Substring.Index
        if let hash = afterPID.range(of: "), name hash: ", options: .backwards) {
            end = hash.lowerBound
        } else if afterPID.hasSuffix(")") {
            end = afterPID.index(before: afterPID.endIndex)
        } else {
            return nil
        }
        let name = LogText.sanitized(String(afterPID[afterPID.index(after: afterPID.startIndex)..<end]))
        return ResolverClient(pid: pid, name: String(name.prefix(64)))
    }

    private static let mnemonics: [Substring: UInt16] = [
        "A": DNSType.a, "NS": DNSType.ns, "CNAME": DNSType.cname, "SOA": DNSType.soa, "PTR": DNSType.ptr,
        "MX": DNSType.mx, "TXT": DNSType.txt, "AAAA": DNSType.aaaa, "SRV": DNSType.srv, "SVCB": DNSType.svcb,
        "HTTPS": DNSType.https, "ANY": DNSType.any,
    ]

    private static func typeNumber(_ mnemonic: Substring) -> UInt16? {
        mnemonics[mnemonic]
    }
}

/// Joins the resolver's queries to mDNSResponder's log events, in memory and bounded.
///
/// Log lines and queries arrive in either order (the log is delivered with some delay), so both
/// sides are matched within `window` of each other. A query is attributed by its message ID first
/// (through the question and its request), and checked against the request's name hash when there
/// is one; else by name hash and type alone. Ambiguous matches (two different clients) give no
/// answer rather than a guess.
public struct ResolverAttribution: Sendable {
    public let window: TimeInterval
    public let capacity: Int

    private struct Request: Sendable {
        let client: ResolverClient
        let nameHash: UInt32?
        let type: UInt16?
        let date: Date
    }

    private var requests: [UInt32: Request] = [:]
    /// Questions by query ID; IDs repeat, so each keeps its date.
    private var questions: [UInt16: [(request: UInt32, date: Date)]] = [:]
    private var order: [(date: Date, request: UInt32?, queryID: UInt16?)] = []

    public init(window: TimeInterval = 5, capacity: Int = 8_192) {
        self.window = window
        self.capacity = capacity
    }

    public mutating func add(_ event: ResolverLogEvent, at date: Date) {
        switch event {
        case .request(let id, let client, let nameHash, let type):
            requests[id] = Request(client: client, nameHash: nameHash, type: type, date: date)
            order.append((date, id, nil))
        case .question(let request, let queryID):
            questions[queryID, default: []].append((request, date))
            order.append((date, nil, queryID))
        }
        if order.count > capacity { prune(keeping: capacity / 2) }
    }

    /// Drops events older than `window` before `date`; call it now and then.
    public mutating func prune(before date: Date) {
        let cutoff = date.addingTimeInterval(-window)
        let keep = order.count - (order.firstIndex { $0.date >= cutoff } ?? order.count)
        prune(keeping: keep)
    }

    private mutating func prune(keeping count: Int) {
        let dropped = order.prefix(order.count - count)
        order.removeFirst(dropped.count)
        guard let newest = dropped.last?.date else { return }
        for entry in dropped {
            if let id = entry.request, let request = requests[id], request.date <= newest { requests[id] = nil }
            if let queryID = entry.queryID {
                questions[queryID]?.removeAll { $0.date <= newest }
                if questions[queryID]?.isEmpty == true { questions[queryID] = nil }
            }
        }
    }

    /// The client behind the query with message ID `queryID` for `name` and `type`, received at
    /// `date`; `nil` when unknown or ambiguous.
    public func client(forQueryID queryID: UInt16, name: DNSName, type: UInt16, at date: Date) -> ResolverClient? {
        let hash = name.mDNSResponderHash
        let near = { (other: Date) in abs(other.timeIntervalSince(date)) <= window }

        var byID = Set<ResolverClient>()
        for question in questions[queryID] ?? [] where near(question.date) {
            guard let request = requests[question.request], near(request.date) else { continue }
            // A request that names its hash must name this one: IDs are only 16 bits.
            if let requestHash = request.nameHash, requestHash != hash { continue }
            byID.insert(request.client)
        }
        if byID.count == 1 { return byID.first }
        if byID.count > 1 { return nil }

        var byHash = Set<ResolverClient>()
        for request in requests.values where request.nameHash == hash && near(request.date) {
            if let requestType = request.type, requestType != type { continue }
            if request.type == nil, type != DNSType.a, type != DNSType.aaaa { continue }
            byHash.insert(request.client)
        }
        return byHash.count == 1 ? byHash.first : nil
    }
}
