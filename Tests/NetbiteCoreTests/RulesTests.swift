import Foundation
import Testing
@testable import NetbiteCore

@Suite struct DomainPatternTests {
    @Test func normalizesHosts() {
        #expect(DomainPattern(" DoubleClick.NET. ")?.description == "doubleclick.net")
        #expect(DomainPattern("*.hotjar.com")?.includesSubdomains == true)
        #expect(DomainPattern("*.hotjar.com")?.host == "hotjar.com")
    }

    @Test func rejectsInvalidHosts() {
        for bad in ["", "-bad.com", "bad-.com", "two..dots", "spa ce.com", "1.2.3.4", "*.", String(repeating: "a", count: 64) + ".com"] {
            #expect(DomainPattern(bad) == nil, "\(bad)")
        }
    }
}

@Suite struct RuleCompilerTests {
    static let geo = GeoIPDatabaseTests.db

    @Test func splitsRulesBetweenPFAndHosts() {
        let blocklist = Blocklist(rules: [
            Rule(target: RuleTarget("doubleclick.net")!),
            Rule(target: RuleTarget("203.0.113.0/24")!),
            Rule(target: RuleTarget("198.51.100.17")!),
            Rule(target: RuleTarget("disabled.example.com")!, isEnabled: false),
        ])
        let compiled = RuleCompiler.compile(blocklist, geo: nil)
        #expect(compiled.hostsDomains == ["doubleclick.net"])
        #expect(compiled.blockTable.map(\.description) == ["198.51.100.17", "203.0.113.0/24"])
        #expect(compiled.geoTable.isEmpty)
        #expect(compiled.warnings.isEmpty)
    }

    @Test func noCountryIsBlockedByDefault() {
        #expect(Blocklist().blockedCountries.isEmpty)
        #expect(RuleCompiler.compile(Blocklist(), geo: Self.geo).geoTable.isEmpty)
    }

    @Test func blocksOptedInCountries() {
        var blocklist = Blocklist()
        blocklist.setCountry("cn", blocked: true)
        blocklist.setCountry("RU", blocked: true)
        let compiled = RuleCompiler.compile(blocklist, geo: Self.geo)
        #expect(compiled.geoTable.map(\.description) == ["1.0.1.0/24", "1.0.2.0/23", "1.0.4.0/22", "5.8.0.0/21", "2001:db8::/32"])

        blocklist.setCountry("CN", blocked: false)
        #expect(RuleCompiler.compile(blocklist, geo: Self.geo).geoTable.map(\.description) == ["5.8.0.0/21"])
    }

    @Test func warnsWhenCountriesCannotBeResolved() {
        let compiled = RuleCompiler.compile(Blocklist(blockedCountries: ["CN"]), geo: nil)
        #expect(compiled.geoTable.isEmpty)
        #expect(compiled.warnings.count == 1)
    }

    @Test func refusesDangerousNetworks() {
        let blocklist = Blocklist(rules: [
            Rule(target: RuleTarget("0.0.0.0/0")!),
            Rule(target: RuleTarget("192.168.1.0/24")!),
            Rule(target: RuleTarget("::/8")!),
            Rule(target: RuleTarget("*.hotjar.com")!),
        ])
        let compiled = RuleCompiler.compile(blocklist, geo: nil)
        #expect(compiled.blockTable.isEmpty)
        #expect(compiled.hostsDomains == ["hotjar.com"])
        #expect(compiled.warnings.count == 4)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = Blocklist(rules: [Rule(target: RuleTarget("*.hotjar.com")!, note: "x")], blockedCountries: ["ru", "CN"])
        let data = try JSONEncoder.netbite.encode(original)
        #expect(String(decoding: data, as: UTF8.self).contains(#""blockedCountries" : [\#n    "CN",\#n    "RU"\#n  ]"#))
        let decoded = try JSONDecoder.netbite.decode(Blocklist.self, from: data)
        #expect(decoded.rules == original.rules)
        #expect(decoded.blockedCountries == ["CN", "RU"])
    }
}

@Suite struct HostsFileTests {
    static let stock = """
    ##
    # Host Database
    ##
    127.0.0.1\tlocalhost
    ::1             localhost

    """

    @Test func addsReplacesAndRemovesTheManagedBlock() {
        let added = HostsFile.render(existing: Self.stock, domains: ["b.example", "a.example"])
        #expect(added.hasPrefix(Self.stock))
        #expect(HostsFile.managedDomains(in: added) == ["a.example", "b.example"])
        #expect(added.contains("0.0.0.0 a.example\n:: a.example\n"))

        let replaced = HostsFile.render(existing: added, domains: ["c.example"])
        #expect(HostsFile.managedDomains(in: replaced) == ["c.example"])
        #expect(replaced.components(separatedBy: HostsFile.beginMarker).count == 2)

        let removed = HostsFile.render(existing: replaced, domains: [])
        #expect(removed == Self.stock)
    }

    @Test func isIdempotent() {
        let once = HostsFile.render(existing: Self.stock, domains: ["a.example"])
        #expect(HostsFile.render(existing: once, domains: ["a.example"]) == once)
    }
}

@Suite struct PFAnchorTests {
    @Test func rulesetReferencesBothTables() {
        let ruleset = PFAnchor.ruleset(tableDirectory: "/Library/Application Support/Netbite")
        #expect(ruleset.contains(#"table <netbite_block> persist file "/Library/Application Support/Netbite/netbite_block.table""#))
        #expect(ruleset.contains("block return out quick to <netbite_geo>"))
        #expect(PFAnchor.name.hasPrefix("com.apple/"))
    }

    @Test func tableFilesHaveOneNetworkPerLine() {
        #expect(PFAnchor.tableFile([CIDR("203.0.113.0/24")!, CIDR("2001:db8::/32")!]) == "203.0.113.0/24\n2001:db8::/32\n")
        #expect(PFAnchor.tableFile([]) == "")
    }
}
