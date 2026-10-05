import Foundation
import Testing
@testable import HectorCore

@Suite struct AllowlistBlocklistTests {
    @Test func blocklistsWithoutAnAllowlistStillDecode() throws {
        // A 0.4.3 blocklist file: no "allowedDomains" key.
        let old = Data(#"{"schemaVersion":1,"rules":[],"blockedCountries":[],"hostsLists":["easyprivacy"]}"#.utf8)
        let blocklist = try JSONDecoder.hector.decode(Blocklist.self, from: old)
        #expect(blocklist.allowedDomains.isEmpty)
        #expect(blocklist.hostsLists == ["easyprivacy"])
        #expect(Blocklist().allowedDomains.isEmpty)
    }

    @Test func entriesAreNormalizedAndRoundTripSorted() throws {
        let json = Data(#"{"schemaVersion":1,"rules":[],"allowedDomains":["Example.COM.","*.cdn.example.net","b.example.org"]}"#.utf8)
        let blocklist = try JSONDecoder.hector.decode(Blocklist.self, from: json)
        #expect(blocklist.allowedDomains == ["example.com", "cdn.example.net", "b.example.org"])
        let data = try JSONEncoder.hector.encode(blocklist)
        #expect(String(decoding: data, as: UTF8.self).contains(#""allowedDomains" : [\#n    "b.example.org",\#n    "cdn.example.net",\#n    "example.com"\#n  ]"#))
        let decoded = try JSONDecoder.hector.decode(Blocklist.self, from: data)
        #expect(decoded == blocklist)
        #expect(decoded != Blocklist())
        #expect(Blocklist(allowedDomains: ["EXAMPLE.com"]).allowedDomains == ["example.com"])
    }

    @Test func invalidEntriesAreRejectedLikePersonalRules() {
        for bad in [#""""#, #""exa mple.com""#, #""203.0.113.7""#, #""-bad.example""#, #""a..b""#, #""x\ny.example""#,
                    #""\#(String(repeating: "a", count: 64)).example""#, #""bad/path.example""#] {
            #expect(DomainPattern(String(bad.dropFirst().dropLast())) == nil, "\(bad)")
            let json = Data(#"{"schemaVersion":1,"rules":[],"allowedDomains":[\#(bad)]}"#.utf8)
            #expect(throws: DecodingError.self, "\(bad)") { try JSONDecoder.hector.decode(Blocklist.self, from: json) }
        }
        var blocklist = Blocklist()
        let refused = blocklist.setAllowed("not a domain", allowed: true)
        #expect(!refused)
        #expect(blocklist.allowedDomains.isEmpty)
        let added = blocklist.setAllowed("Ads.Example.com", allowed: true)
        #expect(added)
        #expect(blocklist.allowedDomains == ["ads.example.com"])
        let removed = blocklist.setAllowed("ads.example.com", allowed: false)
        #expect(removed)
        #expect(blocklist.allowedDomains.isEmpty)
    }

    @Test func theHelperBoundsTheAllowlist() {
        #expect(throws: Never.self) { try HelperLimits.validate(Blocklist(allowedDomains: ["example.com"])) }
        let most = Set((0..<HelperLimits.maximumAllowedDomains).map { "host\($0).example.com" })
        #expect(throws: Never.self) { try HelperLimits.validate(Blocklist(allowedDomains: most)) }
        let tooMany = most.union(["one-more.example.com"])
        #expect(throws: HelperLimits.Violation.self) { try HelperLimits.validate(Blocklist(allowedDomains: tooMany)) }
        // Built in code rather than decoded: the invalid entry is kept, and refused.
        #expect(throws: HelperLimits.Violation.self) { try HelperLimits.validate(Blocklist(allowedDomains: ["bad name"])) }
    }

    @Test func overridingEntryForARuleTarget() {
        let blocklist = Blocklist(allowedDomains: ["example.com"])
        #expect(blocklist.allowlistEntry(overriding: RuleTarget("example.com")!) == "example.com")
        #expect(blocklist.allowlistEntry(overriding: RuleTarget("*.example.com")!) == "example.com")
        #expect(blocklist.allowlistEntry(overriding: RuleTarget("ads.example.com")!) == nil)
        #expect(blocklist.allowlistEntry(overriding: RuleTarget("203.0.113.7")!) == nil)
    }

    @Test func statusFromAnOlderHelperHasNoAllowlist() throws {
        let status = HelperStatus(version: "0.4.3", pfEnabled: true, anchorLoaded: true, appliedAt: nil, blocklist: nil,
                                  blockTableCount: 0, geoTableCount: 0, hostsDomainCount: 0, warnings: [])
        let encoded = try JSONEncoder.hectorWire.encode(status)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("allowlist"))
        let decoded = try JSONDecoder.hector.decode(HelperStatus.self, from: encoded)
        #expect(decoded.allowlistRemovedCount == nil)
        #expect(decoded.allowlistEffects == nil)

        var current = status
        current.allowlistRemovedCount = 3
        current.allowlistEffects = [AllowlistEffect(domain: "example.com", listDomainsRemoved: 2, overriddenRules: [UUID()])]
        let roundTrip = try JSONDecoder.hector.decode(HelperStatus.self, from: JSONEncoder.hectorWire.encode(current))
        #expect(roundTrip == current)
    }

    @Test func olderHelpersAreKnownNotToHonorTheAllowlist() {
        #expect(HelperInfo.current.supportsAllowlist)
        #expect(!HelperInfo.legacy.supportsAllowlist)
        let protocol2 = HelperInfo(version: "0.4.3", protocolVersion: 2, capabilities: HelperCapability.allCases.map(\.rawValue))
        #expect(!protocol2.supportsAllowlist)
        #expect(protocol2.isOutdated)
    }
}

@Suite struct AllowlistCompilerTests {
    static let unified = HostsListCatalog.stevenBlackUnified.id
    static let privacy = HostsListCatalog.easyPrivacy.id

    @Test func removesTheExactNameAndItsSubdomainsFromLists() {
        let blocklist = Blocklist(hostsLists: [Self.unified], allowedDomains: ["example.com"])
        let lists = [Self.unified: ["example.com", "ads.example.com", "a.b.example.com", "badexample.com", "example.com.evil.net", "other.net"]]
        let compiled = RuleCompiler.compile(blocklist, geo: nil, lists: lists)
        #expect(compiled.listDomains == ["badexample.com", "example.com.evil.net", "other.net"])
        #expect(compiled.allowlistEffects == [AllowlistEffect(domain: "example.com", listDomainsRemoved: 3)])
        #expect(compiled.allowlistRemovedCount == 3)
        // Counted before the allowlist, as the list provides them.
        #expect(compiled.listDomainCounts == [Self.unified: 6])
        #expect(compiled.warnings.isEmpty)
    }

    @Test func aNameInSeveralListsCountsOnceForTheMostSpecificEntry() {
        let blocklist = Blocklist(hostsLists: [Self.unified, Self.privacy], allowedDomains: ["example.com", "ads.example.com", "idle.example.org"])
        let lists = [
            Self.unified: ["x.ads.example.com", "cdn.example.com", "keep.example.net"],
            Self.privacy: ["x.ads.example.com", "ads.example.com"],
        ]
        let compiled = RuleCompiler.compile(blocklist, geo: nil, lists: lists)
        #expect(compiled.listDomains == ["keep.example.net"])
        #expect(compiled.allowlistEffects == [
            AllowlistEffect(domain: "ads.example.com", listDomainsRemoved: 2),
            AllowlistEffect(domain: "example.com", listDomainsRemoved: 1),
            AllowlistEffect(domain: "idle.example.org"),
        ])
        #expect(compiled.allowlistRemovedCount == 3)
    }

    @Test func overridesAndReportsPersonalRules() {
        let exact = Rule(target: RuleTarget("tracker.example.com")!)
        let wildcard = Rule(target: RuleTarget("*.tracker.example.com")!)
        let below = Rule(target: RuleTarget("ads.tracker.example.com")!)
        let disabled = Rule(target: RuleTarget("tracker.example.com")!, isEnabled: false)
        let network = Rule(target: RuleTarget("203.0.113.0/24")!)
        let blocklist = Blocklist(rules: [exact, wildcard, below, disabled, network], hostsLists: [Self.unified],
                                  allowedDomains: ["tracker.example.com"])
        let compiled = RuleCompiler.compile(blocklist, geo: nil, lists: [Self.unified: ["tracker.example.com", "ads.tracker.example.com"]])
        // The allowlist wins over the user's own rules for that exact name; a rule for a name
        // below it stays, and lists lose the whole subtree.
        #expect(compiled.hostsDomains == ["ads.tracker.example.com"])
        #expect(compiled.listDomains.isEmpty)
        #expect(compiled.blockTable == [CIDR("203.0.113.0/24")!])
        #expect(compiled.allowlistEffects == [AllowlistEffect(domain: "tracker.example.com", listDomainsRemoved: 2,
                                                              overriddenRules: [exact.id, wildcard.id])])
        // tracker.example.com is both a list name and a personal one: counted once.
        #expect(compiled.allowlistRemovedCount == 2)
        // No "cannot match subdomains" warning for the overridden wildcard rule.
        #expect(compiled.warnings.isEmpty)
        let hosts = HostsFile.render(existing: "", domains: compiled.hostsDomains, listDomains: compiled.listDomains)
        #expect(HostsFile.managedDomains(in: hosts) == ["ads.tracker.example.com"])
    }

    @Test func allowedNamesDoNotCountTowardsTheCap() {
        var warnings: [String] = []
        let domains = (0..<6).map { "host\($0).example.com" } + ["a.allowed.example", "b.allowed.example"]
        let result = RuleCompiler.compileLists([Self.unified], lists: [Self.unified: domains], personal: [],
                                               allowed: ["allowed.example"], warnings: &warnings, limit: 6)
        #expect(result.domains.count == 6)
        #expect(result.removed == ["allowed.example": 2])
        #expect(warnings.isEmpty)
    }

    @Test func invalidEntriesAreIgnoredByTheCompiler() {
        // Only reachable by building a blocklist in code; the helper refuses it before compiling.
        let blocklist = Blocklist(rules: [Rule(target: RuleTarget("ads.example.com")!)], allowedDomains: ["bad name", "ads.example.com"])
        let compiled = RuleCompiler.compile(blocklist, geo: nil)
        #expect(compiled.hostsDomains.isEmpty)
        #expect(compiled.allowlistEffects.map(\.domain) == ["ads.example.com"])
    }

    @Test func coveringEntryFollowsLabelBoundaries() {
        let allowed: Set<String> = ["example.com", "deep.a.example.com"]
        #expect(RuleCompiler.allowlistEntry(covering: "example.com", in: allowed) == "example.com")
        #expect(RuleCompiler.allowlistEntry(covering: "x.deep.a.example.com", in: allowed) == "deep.a.example.com")
        #expect(RuleCompiler.allowlistEntry(covering: "a.example.com", in: allowed) == "example.com")
        #expect(RuleCompiler.allowlistEntry(covering: "notexample.com", in: allowed) == nil)
        #expect(RuleCompiler.allowlistEntry(covering: "com", in: allowed) == nil)
        #expect(RuleCompiler.allowlistEntry(covering: "example.com", in: []) == nil)
    }

    @Test func noAllowlistChangesNothing() {
        let blocklist = Blocklist(rules: [Rule(target: RuleTarget("mine.example")!)], hostsLists: [Self.unified])
        let compiled = RuleCompiler.compile(blocklist, geo: nil, lists: [Self.unified: ["a.example.com", "mine.example"]])
        #expect(compiled.hostsDomains == ["mine.example"])
        #expect(compiled.listDomains == ["a.example.com"])
        #expect(compiled.allowlistEffects.isEmpty)
        #expect(compiled.allowlistRemovedCount == 0)
    }
}
