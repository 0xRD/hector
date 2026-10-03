import Foundation

/// A third-party blocklist Hector can subscribe to. Only lists from the built-in catalog exist:
/// the helper downloads them itself, as root, from these fixed HTTPS addresses.
public struct HostsListSource: Hashable, Sendable, Identifiable {
    /// Stable identifier stored in blocklists (`Blocklist.hostsLists`).
    public let id: String
    public let name: String
    public let summary: String
    /// Where the helper downloads the list. Fixed in the code, never sent by a client.
    public let url: URL
    public let homepage: URL
    public let license: String
    /// A download with fewer valid domains is refused as truncated or wrong (an error page, an
    /// emptied file), and the last good copy stays in force.
    public let minimumDomains: Int

    public init(id: String, name: String, summary: String, url: URL, homepage: URL, license: String, minimumDomains: Int) {
        self.id = id
        self.name = name
        self.summary = summary
        self.url = url
        self.homepage = homepage
        self.license = license
        self.minimumDomains = minimumDomains
    }
}

/// The built-in catalog of hosts lists and the bounds that apply to them.
public enum HostsListCatalog {
    public static let stevenBlackUnified = HostsListSource(
        id: "stevenblack-unified",
        name: "StevenBlack Unified",
        summary: "Ads and malware, merged from reputable sources. About 70,000 domains.",
        url: URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!,
        homepage: URL(string: "https://github.com/StevenBlack/hosts")!,
        license: "MIT",
        minimumDomains: 10_000
    )

    /// EasyPrivacy is an Adblock Plus filter list; hMirror (the source of the hBlock project)
    /// publishes the domains of its whole-domain rules as a plain list, updated daily.
    public static let easyPrivacy = HostsListSource(
        id: "easyprivacy",
        name: "EasyPrivacy",
        summary: "Trackers and analytics, the domains of EasyPrivacy's whole-domain rules (converted by hMirror). About 40,000 domains.",
        url: URL(string: "https://raw.githubusercontent.com/hectorm/hmirror/master/data/easyprivacy/list.txt")!,
        homepage: URL(string: "https://easylist.to")!,
        license: "GPL-3.0 or CC BY-SA 3.0",
        minimumDomains: 5_000
    )

    public static let all: [HostsListSource] = [stevenBlackUnified, easyPrivacy]

    public static func source(_ id: String) -> HostsListSource? {
        all.first { $0.id == id }
    }

    /// Identifier shape, checked when decoding: 1 to 64 characters among a–z, 0–9 and `-`.
    public static func isIdentifier(_ id: String) -> Bool {
        let utf8 = id.utf8
        guard (1...64).contains(utf8.count) else { return false }
        return utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
        }
    }

    // MARK: Bounds

    /// A response larger than this (after HTTP decompression) is refused while it downloads.
    public static let maximumDownloadSize = 16 * 1024 * 1024
    /// A list with more valid domains than this is refused as implausible.
    public static let maximumDomainsPerList = 300_000
    /// All lists together never put more than this many domains in /etc/hosts.
    public static let maximumListDomains = 400_000
    /// Longer lines are counted as invalid without being looked at.
    public static let maximumLineLength = 1_024
    /// Each request must progress within this many seconds, and the whole download end within
    /// `resourceTimeout`: the helper serves one request at a time while it downloads.
    public static let requestTimeout: TimeInterval = 20
    public static let resourceTimeout: TimeInterval = 30

    // MARK: Schedule

    /// Enabled lists are checked again after a week (a conditional request: usually a 304).
    public static let refreshInterval: TimeInterval = 7 * 24 * 3_600
    /// After a failed download, wait this long before trying again on schedule.
    public static let retryInterval: TimeInterval = 6 * 3_600
    /// How often the helper looks at whether a list is due.
    public static let checkInterval: TimeInterval = 15 * 60

    /// Names a list can never block: the hosts Hector downloads from, so a list cannot stop its
    /// own updates or the country database. Personal rules may still block them.
    public static var protectedHosts: Set<String> {
        var hosts: Set<String> = ["download.db-ip.com", "github.com"]
        for source in all {
            if let host = source.url.host() { hosts.insert(host.lowercased()) }
        }
        return hosts
    }
}

/// What the helper knows about one subscribed list. Reported in `HelperStatus.hostsLists`.
public struct HostsListState: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Valid domains in the copy in force.
    public var domainCount: Int
    /// Lines of that copy that were malformed or held an invalid name.
    public var invalidLines: Int
    /// Entries left out on purpose: localhost and other reserved names, redirections to a real
    /// address, the hosts Hector downloads from.
    public var skippedEntries: Int
    /// When the copy in force was downloaded.
    public var updatedAt: Date?
    /// The last successful check, including "not modified" answers.
    public var checkedAt: Date?
    /// The last attempt, successful or not.
    public var attemptedAt: Date?
    /// Why the last attempt failed; `nil` after a success.
    public var lastError: String?
    /// Validators for conditional requests.
    public var etag: String?
    public var lastModified: String?

    public init(id: String, domainCount: Int = 0, invalidLines: Int = 0, skippedEntries: Int = 0, updatedAt: Date? = nil,
                checkedAt: Date? = nil, attemptedAt: Date? = nil, lastError: String? = nil, etag: String? = nil,
                lastModified: String? = nil) {
        self.id = id
        self.domainCount = domainCount
        self.invalidLines = invalidLines
        self.skippedEntries = skippedEntries
        self.updatedAt = updatedAt
        self.checkedAt = checkedAt
        self.attemptedAt = attemptedAt
        self.lastError = lastError
        self.etag = etag
        self.lastModified = lastModified
    }

    /// Whether the list should be downloaded again on schedule at `now`.
    public func isDue(at now: Date) -> Bool {
        if let attemptedAt, now.timeIntervalSince(attemptedAt) < HostsListCatalog.retryInterval {
            return false
        }
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= HostsListCatalog.refreshInterval
    }
}

// MARK: - Parser

/// The result of parsing a hosts list.
public struct HostsListParseResult: Sendable, Equatable {
    /// Valid, lowercased, ASCII (punycode) domains, sorted, without duplicates.
    public var domains: [String]
    /// Malformed lines and lines with an invalid name.
    public var invalidLines: Int
    /// Reserved names, redirections and protected hosts, left out on purpose.
    public var skippedEntries: Int
    /// The list had more domains than allowed; `domains` stops at the limit.
    public var exceededLimit: Bool
}

/// A strict parser for hosts files (`0.0.0.0 example.com`) and plain domain lists (`example.com`).
///
/// Whatever address a line names, Hector only ever points the domain at 0.0.0.0 and `::`: a line
/// that maps a name to a real address (`203.0.113.7 bank.example`) would be a redirection, not a
/// block, and is skipped. Localhost and other reserved names are never touched.
public enum HostsListParser {
    /// Addresses that mean "block" in a hosts list.
    static let sinkAddresses: Set<IPAddress> = [.v4(0), .v4(0x7F00_0001), .v6(0), .v6(1)]

    /// Names that belong to the system's own hosts file.
    static let reservedNames: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "localdomain",
        "ip6-localhost", "ip6-loopback", "ip6-localnet", "ip6-mcastprefix",
        "ip6-allnodes", "ip6-allrouters", "ip6-allhosts",
    ]

    static let reservedSuffixes = [".local", ".localhost", ".localdomain", ".arpa", ".home.arpa", ".internal"]

    /// "\r\n" is a single Character in Swift.
    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    private static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private enum Entry {
        case domain(String)
        case invalid
        case skipped
    }

    /// Parses UTF-8 data. Data that is not valid UTF-8 parses to nothing, with one invalid line.
    public static func parse(_ data: Data, maximumDomains: Int = HostsListCatalog.maximumDomainsPerList,
                             protectedHosts: Set<String> = HostsListCatalog.protectedHosts) -> HostsListParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return HostsListParseResult(domains: [], invalidLines: 1, skippedEntries: 0, exceededLimit: false)
        }
        return parse(text, maximumDomains: maximumDomains, protectedHosts: protectedHosts)
    }

    public static func parse(_ text: String, maximumDomains: Int = HostsListCatalog.maximumDomainsPerList,
                             protectedHosts: Set<String> = HostsListCatalog.protectedHosts) -> HostsListParseResult {
        var domains = Set<String>()
        var invalid = 0
        var skipped = 0
        var exceeded = false

        // A byte order mark would otherwise stick to the first token.
        let body: Substring = text.hasPrefix("\u{FEFF}") ? text.dropFirst() : text[...]
        lines: for line in body.split(omittingEmptySubsequences: true, whereSeparator: isLineBreak) {
            guard line.utf8.count <= HostsListCatalog.maximumLineLength else {
                invalid += 1
                continue
            }
            var lineIsInvalid = false
            for entry in entries(in: line, protectedHosts: protectedHosts) {
                switch entry {
                case .invalid:
                    lineIsInvalid = true
                case .skipped:
                    skipped += 1
                case .domain(let domain):
                    if domains.contains(domain) { continue }
                    guard domains.count < maximumDomains else {
                        exceeded = true
                        break lines
                    }
                    domains.insert(domain)
                }
            }
            if lineIsInvalid { invalid += 1 }
        }
        return HostsListParseResult(domains: domains.sorted(), invalidLines: invalid, skippedEntries: skipped, exceededLimit: exceeded)
    }

    /// The entries of one line; empty for blank and comment lines.
    private static func entries(in line: Substring, protectedHosts: Set<String>) -> [Entry] {
        let content: Substring
        if let hash = line.firstIndex(of: "#") {
            content = line[..<hash]
        } else {
            content = line
        }
        let tokens: [Substring] = content.split(whereSeparator: isBlank)
        guard let first = tokens.first else { return [] }

        let names: ArraySlice<Substring>
        if let address = IPAddress(String(first)) {
            guard sinkAddresses.contains(address) else {
                // A redirection to a real address: never followed, never blocked.
                return [.skipped]
            }
            names = tokens.dropFirst()
            if names.isEmpty { return [.invalid] }
        } else if tokens.count == 1 {
            // A plain domain list: one name per line.
            names = tokens[...]
        } else {
            return [.invalid]
        }
        return names.map { entry(for: $0, protectedHosts: protectedHosts) }
    }

    private static func entry(for token: Substring, protectedHosts: Set<String>) -> Entry {
        guard !token.contains("*"), let host = normalizedHost(String(token)) else { return .invalid }
        if isReserved(host) || protectedHosts.contains(host) { return .skipped }
        return .domain(host)
    }

    /// Lowercased ASCII form of `raw`, with international names converted to punycode, or `nil`
    /// when it is not a valid host name.
    static func normalizedHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        if !host.utf8.allSatisfy({ $0 < 0x80 }) {
            guard let ascii = IDNA.toASCII(host) else { return nil }
            host = ascii
        }
        guard let pattern = DomainPattern(host), !pattern.includesSubdomains else { return nil }
        return pattern.host
    }

    /// Reserved, local and single-label names: blocking them could break the system or the LAN.
    static func isReserved(_ host: String) -> Bool {
        if reservedNames.contains(host) || !host.contains(".") { return true }
        return reservedSuffixes.contains { host.hasSuffix($0) }
    }
}

// MARK: - International names

/// Conversion of international domain names to their ASCII form (punycode, RFC 3492).
///
/// This is the encoding step of IDNA with Unicode normalization (NFC) and lowercasing. It does not
/// implement every rule of UTS #46: a label made of letters, digits and marks is converted, any
/// other non-ASCII character makes the name invalid. The result goes through `DomainPattern` like
/// any other name.
public enum IDNA {
    public static func toASCII(_ host: String) -> String? {
        let normalized = host.precomposedStringWithCanonicalMapping.lowercased()
        var labels: [String] = []
        for label in normalized.split(separator: ".", omittingEmptySubsequences: false) {
            if label.utf8.allSatisfy({ $0 < 0x80 }) {
                labels.append(String(label))
                continue
            }
            guard label.unicodeScalars.allSatisfy(isAllowed), let encoded = Punycode.encode(String(label)) else { return nil }
            labels.append("xn--" + encoded)
        }
        return labels.joined(separator: ".")
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return true }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}

/// The Bootstring encoding of RFC 3492 with the punycode parameters.
public enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    /// The punycode form of `input`, without the `xn--` prefix; `nil` on overflow.
    public static func encode(_ input: String) -> String? {
        let codePoints: [Int] = input.unicodeScalars.map { Int($0.value) }
        var output: [UInt8] = codePoints.filter { $0 < 0x80 }.map { UInt8($0) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append(UInt8(ascii: "-")) }

        var n = initialN
        var delta = 0
        var bias = initialBias
        // Labels are at most 63 characters: anything longer is invalid anyway, and this keeps
        // every product below far from overflowing.
        guard codePoints.count <= 63 else { return nil }

        while handled < codePoints.count {
            guard let next = codePoints.filter({ $0 >= n }).min() else { return nil }
            delta += (next - n) * (handled + 1)
            n = next
            for codePoint in codePoints {
                if codePoint < n { delta += 1 }
                guard codePoint == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = threshold(k: k, bias: bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta: delta, points: handled + 1, first: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func threshold(k: Int, bias: Int) -> Int {
        if k <= bias { return tMin }
        if k >= bias + tMax { return tMax }
        return k - bias
    }

    private static func digit(_ value: Int) -> UInt8 {
        value < 26 ? UInt8(97 + value) : UInt8(22 + value)  // a–z, then 0–9
    }

    private static func adapt(delta: Int, points: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base * delta) / (delta + skew)
    }
}
