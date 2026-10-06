/// Why a destination is blocked by a blocklist.
public enum BlockReason: Equatable, Sendable {
    /// An enabled IP or network rule covers the address.
    case network(CIDR)
    /// The address belongs to a blocked country.
    case country(String)
}

extension Blocklist {
    /// How this blocklist treats `address` (located in `country`), the way pf will once applied.
    /// Domain rules are not considered: a socket only knows the address, not the name the app asked for.
    public func blockReason(for address: IPAddress, country: String?) -> BlockReason? {
        for rule in rules where rule.isEnabled {
            if case .network(let cidr) = rule.target, cidr.contains(address) {
                return .network(cidr)
            }
        }
        if let country, blockedCountries.contains(country) {
            return .country(country)
        }
        return nil
    }

    /// The rule, switched on or off, that targets exactly this address, if any.
    public func addressRule(for address: IPAddress) -> Rule? {
        rules.first { rule in
            if case .network(let cidr) = rule.target { return cidr == CIDR(address) }
            return false
        }
    }
}
