import Foundation

/// The blocklist turned into what the system understands: two pf tables and a hosts block.
public struct CompiledBlocklist: Sendable {
    /// Addresses and networks from user rules → pf table `<netbite_block>`.
    public var blockTable: [CIDR]
    /// Every range of every blocked country → pf table `<netbite_geo>`.
    public var geoTable: [CIDR]
    /// Host names of personal rules → `/etc/hosts`, pointed at 0.0.0.0 and ::.
    public var hostsDomains: [String]
    /// Rules that were skipped or only partly applied, in plain words.
    public var warnings: [String]
    /// Host names from subscribed hosts lists, sorted, without the personal ones → the lists part
    /// of the `/etc/hosts` section.
    public var listDomains: [String] = []
    /// Valid domains of each subscribed list that was available, by list identifier.
    public var listDomainCounts: [String: Int] = [:]
}

public enum RuleCompiler {
    /// Networks wider than this are refused: a typo like `/2` would cut the Mac off the internet.
    public static let widestIPv4Prefix = 8
    public static let widestIPv6Prefix = 16

    /// Compiles enabled rules. `geo` is needed only when countries are blocked; `lists` holds the
    /// parsed domains of the hosts lists available, by identifier (lists not subscribed are ignored).
    public static func compile(_ blocklist: Blocklist, geo: GeoIPDatabase?, lists: [String: [String]] = [:]) -> CompiledBlocklist {
        var block = Set<CIDR>()
        var domains = Set<String>()
        var warnings: [String] = []

        for rule in blocklist.rules where rule.isEnabled {
            switch rule.target {
            case .network(let cidr):
                let widest = cidr.network.isV4 ? widestIPv4Prefix : widestIPv6Prefix
                if cidr.prefixLength < widest {
                    warnings.append("Skipped \(cidr): networks wider than /\(widest) are refused.")
                } else if !isSafeToBlock(cidr) {
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
                    // The same rails as user rules: a corrupted or forged database must not be able
                    // to block the whole internet or the local network.
                    let safe = networks.filter { isSafeToBlock($0) }
                    if safe.count < networks.count {
                        warnings.append("Country \(code): \(networks.count - safe.count) networks skipped (too wide, or local).")
                    }
                    geoTable += safe
                }
            } else {
                warnings.append("Countries \(countries.joined(separator: ", ")) are not blocked: no GeoIP database. Run `hector geo update`.")
            }
        }

        let fromLists = compileLists(blocklist.hostsLists, lists: lists, personal: domains, warnings: &warnings)

        return CompiledBlocklist(
            blockTable: block.sorted(),
            geoTable: geoTable.sorted(),
            hostsDomains: domains.sorted(),
            warnings: warnings,
            listDomains: fromLists.domains,
            listDomainCounts: fromLists.counts
        )
    }

    /// The union of the subscribed lists, without the personal domains, capped at
    /// `HostsListCatalog.maximumListDomains`. Every name is checked again, so a damaged cache
    /// cannot put a reserved name or a malformed line into /etc/hosts.
    static func compileLists(_ subscribed: Set<String>, lists: [String: [String]], personal: Set<String>,
                             warnings: inout [String],
                             limit: Int = HostsListCatalog.maximumListDomains) -> (domains: [String], counts: [String: Int]) {
        var union = Set<String>()
        var counts: [String: Int] = [:]
        var capped = false
        let protected = HostsListCatalog.protectedHosts
        for id in subscribed.sorted() {
            guard let source = HostsListCatalog.source(id) else {
                warnings.append("Unknown hosts list \(id): skipped.")
                continue
            }
            guard let domains = lists[id] else {
                warnings.append("\(source.name) is not downloaded yet; it applies once the helper has a copy.")
                continue
            }
            var valid = 0
            for domain in domains {
                guard isListDomain(domain, protected: protected) else { continue }
                valid += 1
                if personal.contains(domain) || union.contains(domain) { continue }
                if union.count >= limit {
                    capped = true
                    continue
                }
                union.insert(domain)
            }
            counts[id] = valid
        }
        if capped {
            warnings.append("Hosts lists hold more than \(Display.count(limit)) domains together; the rest were left out.")
        }
        return (union.sorted(), counts)
    }

    /// A name a list may put into /etc/hosts: already normalized, valid, not reserved, not protected.
    static func isListDomain(_ domain: String, protected: Set<String>) -> Bool {
        guard let pattern = DomainPattern(domain), !pattern.includesSubdomains, pattern.host == domain else { return false }
        return !HostsListParser.isReserved(domain) && !protected.contains(domain)
    }

    /// Not wider than the limits, and neither inside nor covering a local or private range.
    static func isSafeToBlock(_ cidr: CIDR) -> Bool {
        let widest = cidr.network.isV4 ? widestIPv4Prefix : widestIPv6Prefix
        guard cidr.prefixLength >= widest else { return false }
        return !IPAddress.localNetworks.contains { local in
            local.contains(cidr.network) || cidr.contains(local.network)
        }
    }
}
