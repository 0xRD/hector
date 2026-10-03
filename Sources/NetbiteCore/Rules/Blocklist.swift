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

    public init(rules: [Rule] = [], blockedCountries: Set<String> = []) {
        self.schemaVersion = 1
        self.rules = rules
        self.blockedCountries = Set(blockedCountries.map { $0.uppercased() })
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

    // Countries are written sorted so the file diffs cleanly.
    private enum CodingKeys: String, CodingKey { case schemaVersion, rules, blockedCountries }

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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(rules, forKey: .rules)
        try container.encode(blockedCountries.sorted(), forKey: .blockedCountries)
    }

    public static func load(from url: URL) throws -> Blocklist {
        try JSONDecoder.netbite.decode(Blocklist.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try JSONEncoder.netbite.encode(self).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    public static var netbite: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONEncoder {
    /// Single-line JSON for the helper socket, where a newline ends a message.
    public static var netbiteWire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var netbite: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
