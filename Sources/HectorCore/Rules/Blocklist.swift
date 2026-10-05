import Foundation

/// What a rule blocks.
public enum RuleTarget: Hashable, Sendable {
    /// Goes to `/etc/hosts`.
    case domain(DomainPattern)
    /// An address or network; goes to the pf table `<netbite_block>`.
    case network(CIDR)

    /// Parses `"203.0.113.0/24"`, `"198.51.100.7"`, `"*.example.com"` or `"example.com"`.
    public init?(_ string: String) {
        if let cidr = CIDR(string) {
            self = .network(cidr)
        } else if let domain = DomainPattern(string) {
            self = .domain(domain)
        } else {
            return nil
        }
    }
}

extension RuleTarget: CustomStringConvertible {
    public var description: String {
        switch self {
        case .domain(let domain): domain.description
        case .network(let cidr): cidr.description
        }
    }
}

extension RuleTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case domain, network }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .domain:
            guard let domain = DomainPattern(value) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid domain: \(value)")
            }
            self = .domain(domain)
        case .network:
            guard let cidr = CIDR(value) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid network: \(value)")
            }
            self = .network(cidr)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .domain(let domain):
            try container.encode(Kind.domain, forKey: .kind)
            try container.encode(domain.description, forKey: .value)
        case .network(let cidr):
            try container.encode(Kind.network, forKey: .kind)
            try container.encode(cidr.description, forKey: .value)
        }
    }
}

public struct Rule: Codable, Hashable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Typed in the blocklist editor or the CLI.
        case manual
        /// Created with "Block this destination" in the connections view.
        case connections
    }

    public var id: UUID
    public var target: RuleTarget
    public var isEnabled: Bool
    public var note: String?
    public var source: Source
    public var createdAt: Date

    public init(id: UUID = UUID(), target: RuleTarget, isEnabled: Bool = true, note: String? = nil,
                source: Source = .manual, createdAt: Date = Date()) {
        self.id = id
        self.target = target
        self.isEnabled = isEnabled
        self.note = note
        self.source = source
        // ISO 8601 in the JSON file keeps whole seconds; truncate now so a saved rule equals itself.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }
}

/// Everything the user wants blocked. Persisted as JSON.
public struct Blocklist: Codable, Sendable {
    public var schemaVersion: Int
    public var rules: [Rule]
    /// ISO 3166-1 alpha-2 codes whose every IP range is blocked. Empty by default: country blocking
    /// is strictly opt-in.
    public var blockedCountries: Set<String>
    /// Identifiers of the subscribed hosts lists (`HostsListCatalog`). Empty by default. Only the
    /// identifiers travel: the helper downloads the lists itself.
    public var hostsLists: Set<String>
    /// The allowlist: host names that are never blocked by name, in normalized form (lowercased,
    /// no trailing dot, see `normalizedAllowedDomain`). It wins over everything that goes to
    /// /etc/hosts, the user's own domain rules included (docs/LOCAL_DNS.md, decision 4):
    /// - an entry removes that exact name and every name below it from the hosts lists;
    /// - an entry removes that exact name from the personal domain rules (`ads.example.com`
    ///   blocked by a personal rule stays blocked when `example.com` is allowed).
    /// Networks and countries (pf) are not affected. Empty by default.
    public var allowedDomains: Set<String>

    public init(rules: [Rule] = [], blockedCountries: Set<String> = [], hostsLists: Set<String> = [],
                allowedDomains: Set<String> = []) {
        self.schemaVersion = 1
        self.rules = rules
        self.blockedCountries = Set(blockedCountries.map { $0.uppercased() })
        self.hostsLists = hostsLists
        // Invalid entries are kept as given, so that `HelperLimits.validate` reports them.
        self.allowedDomains = Set(allowedDomains.map { Self.normalizedAllowedDomain($0) ?? $0 })
    }

    /// The normalized form of an allowlist entry, or `nil` when it is not a valid host name. The
    /// validator is the one of personal domain rules (`DomainPattern`); `*.example.com` is accepted
    /// and means `example.com`, since every entry already covers the names below it in lists.
    public static func normalizedAllowedDomain(_ raw: String) -> String? {
        DomainPattern(raw)?.host
    }

    /// Adds or removes an allowlist entry. Returns `false`, changing nothing, when `domain` is not
    /// a valid host name.
    @discardableResult
    public mutating func setAllowed(_ domain: String, allowed: Bool) -> Bool {
        guard let host = Self.normalizedAllowedDomain(domain) else { return false }
        if allowed {
            allowedDomains.insert(host)
        } else {
            allowedDomains.remove(host)
        }
        return true
    }

    /// The allowlist entry that overrides a block rule with this target, or `nil`. Only domain
    /// targets can be overridden, and only by an entry for the same host. For the app: show
    /// "overridden by allowlist" on a rule, warn before saving one.
    public func allowlistEntry(overriding target: RuleTarget) -> String? {
        guard case .domain(let pattern) = target, allowedDomains.contains(pattern.host) else { return nil }
        return pattern.host
    }

    /// ISO 3166-1 alpha-2 shape: exactly two ASCII letters A–Z.
    public static func isCountryCode(_ code: String) -> Bool {
        code.utf8.count == 2 && code.utf8.allSatisfy { (65...90).contains($0) }
    }

    public mutating func setCountry(_ code: String, blocked: Bool) {
        if blocked {
            blockedCountries.insert(code.uppercased())
        } else {
            blockedCountries.remove(code.uppercased())
        }
    }

    public mutating func setHostsList(_ id: String, enabled: Bool) {
        if enabled {
            hostsLists.insert(id)
        } else {
            hostsLists.remove(id)
        }
    }

    // Countries and lists are written sorted so the file diffs cleanly. Files written before hosts
    // lists existed have no `hostsLists` key and decode with none.
    // Files written before the allowlist existed have no `allowedDomains` key and decode with an
    // empty one; apps that predate it ignore the key.
    private enum CodingKeys: String, CodingKey { case schemaVersion, rules, blockedCountries, hostsLists, allowedDomains }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        let countries = try container.decodeIfPresent([String].self, forKey: .blockedCountries) ?? []
        blockedCountries = Set(countries.map { $0.uppercased() })
        guard blockedCountries.allSatisfy(Self.isCountryCode) else {
            throw DecodingError.dataCorruptedError(forKey: .blockedCountries, in: container,
                                                   debugDescription: "Country codes are two letters, A to Z.")
        }
        let lists = try container.decodeIfPresent([String].self, forKey: .hostsLists) ?? []
        hostsLists = Set(lists)
        // Shape only: an identifier this version does not know is reported by the compiler, so a
        // blocklist saved by a newer version still loads.
        guard hostsLists.allSatisfy(HostsListCatalog.isIdentifier) else {
            throw DecodingError.dataCorruptedError(forKey: .hostsLists, in: container,
                                                   debugDescription: "Hosts list identifiers are 1 to 64 characters: a-z, 0-9 and -.")
        }
        let allowed = try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? []
        var normalized = Set<String>()
        for entry in allowed {
            guard let host = Self.normalizedAllowedDomain(entry) else {
                throw DecodingError.dataCorruptedError(forKey: .allowedDomains, in: container,
                                                       debugDescription: "Allowlist entries are host names, checked like personal domain rules.")
            }
            normalized.insert(host)
        }
        allowedDomains = normalized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(rules, forKey: .rules)
        try container.encode(blockedCountries.sorted(), forKey: .blockedCountries)
        try container.encode(hostsLists.sorted(), forKey: .hostsLists)
        try container.encode(allowedDomains.sorted(), forKey: .allowedDomains)
    }

    public static func load(from url: URL) throws -> Blocklist {
        try JSONDecoder.hector.decode(Blocklist.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try JSONEncoder.hector.encode(self).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    public static var hector: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONEncoder {
    /// Single-line JSON for the helper socket, where a newline ends a message.
    public static var hectorWire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var hector: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
