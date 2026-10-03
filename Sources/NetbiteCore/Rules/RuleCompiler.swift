import Foundation

/// The blocklist turned into what the system understands: two pf tables and a hosts block.
public struct CompiledBlocklist: Sendable {
    /// Addresses and networks from user rules → pf table `<netbite_block>`.
    public var blockTable: [CIDR]
    /// Every range of every blocked country → pf table `<netbite_geo>`.
    public var geoTable: [CIDR]
    /// Host names → `/etc/hosts`, pointed at 0.0.0.0 and ::.
    public var hostsDomains: [String]
    /// Rules that were skipped or only partly applied, in plain words.
    public var warnings: [String]
}

public enum RuleCompiler {
    /// Networks wider than this are refused: a typo like `/2` would cut the Mac off the internet.
    public static let widestIPv4Prefix = 8
    public static let widestIPv6Prefix = 16

    /// Compiles enabled rules. `geo` is needed only when countries are blocked.
    public static func compile(_ blocklist: Blocklist, geo: GeoIPDatabase?) -> CompiledBlocklist {
        var block = Set<CIDR>()
        var domains = Set<String>()
        var warnings: [String] = []

        for rule in blocklist.rules where rule.isEnabled {
            switch rule.target {
            case .network(let cidr):
                let widest = cidr.network.isV4 ? widestIPv4Prefix : widestIPv6Prefix
                if cidr.prefixLength < widest {
                    warnings.append("Skipped \(cidr): networks wider than /\(widest) are refused.")
                } else if cidr.network.isLocalOrPrivate {
                    warnings.append("Skipped \(cidr): local and private networks are never blocked.")
                } else {
                    block.insert(cidr)
                }
            case .domain(let domain):
                domains.insert(domain.host)
                if domain.includesSubdomains {
                    warnings.append("\(domain): /etc/hosts cannot match subdomains, only \(domain.host) is blocked.")
                }
            }
        }

        var geoTable: [CIDR] = []
        let countries = blocklist.blockedCountries.sorted()
        if !countries.isEmpty {
            if let geo {
                for code in countries {
                    let networks = geo.networks(for: code)
                    if networks.isEmpty {
                        warnings.append("Country \(code) has no range in the GeoIP database.")
                    }
                    geoTable += networks
                }
            } else {
                warnings.append("Countries \(countries.joined(separator: ", ")) are not blocked: no GeoIP database. Run `netbite geo update`.")
            }
        }

        return CompiledBlocklist(
            blockTable: block.sorted(),
            geoTable: geoTable.sorted(),
            hostsDomains: domains.sorted(),
            warnings: warnings
        )
    }
}
