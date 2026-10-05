import Foundation
import Testing
@testable import HectorCore

@Suite struct HostsListParserTests {
    /// The head of StevenBlack's file, with the cases a list may contain.
    static let sample = """
    # Title: StevenBlack/hosts
    #
    127.0.0.1 localhost
    127.0.0.1 localhost.localdomain
    127.0.0.1 local
    255.255.255.255 broadcasthost
    ::1 localhost
    ::1 ip6-localhost
    fe80::1%lo0 localhost
    ff02::1 ip6-allnodes
    0.0.0.0 0.0.0.0

    # Start StevenBlack
    0.0.0.0 ads.example.com
    0.0.0.0 Tracker.Example.NET. # tracking
    0.0.0.0\tTabs.example.org
    127.0.0.1 loopback.example.com
    :: six.example.com
    0.0.0.0 ads.example.com
    0.0.0.0 one.example.com two.example.com
    """

    /// The shape of HaGeZi's hosts-format files: a comment header, then `0.0.0.0 name` lines that
    /// spell out subdomains.
    @Test func readsHaGeZiHostsFormat() {
        let text = "# Title: HaGeZi's Multi LIGHT\n# Syntax: Hosts (including possible subdomains)\n# Number of entries: 3\n#\n"
            + "0.0.0.0 000webhost.com\n0.0.0.0 www.000webhost.com\n0.0.0.0 telemetry.example-studio.com\n"
        let result = HostsListParser.parse(text)
        #expect(result.domains == ["000webhost.com", "telemetry.example-studio.com", "www.000webhost.com"])
        #expect(result.invalidLines == 0)
        #expect(result.skippedEntries == 0)
    }

    @Test func readsHostsLines() {
        let result = HostsListParser.parse(Self.sample)
        #expect(result.domains == [
            "ads.example.com", "loopback.example.com", "one.example.com", "six.example.com", "tabs.example.org",
            "tracker.example.net", "two.example.com",
        ])
        #expect(!result.exceededLimit)
    }

    @Test func neverTouchesLocalhostAndReservedNames() {
        let result = HostsListParser.parse(Self.sample)
        for reserved in ["localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-allnodes"] {
            #expect(!result.domains.contains(reserved), "\(reserved)")
        }
        let more = HostsListParser.parse("0.0.0.0 printer.local\n0.0.0.0 router.home.arpa\n0.0.0.0 1.0.0.127.in-addr.arpa\n0.0.0.0 wpad\n")
        #expect(more.domains.isEmpty)
        #expect(more.skippedEntries == 4)
    }

    @Test func countsInvalidAndSkippedLines() {
        let result = HostsListParser.parse(Self.sample)
        // "0.0.0.0 0.0.0.0" (an address is not a name).
        #expect(result.invalidLines == 1)
        // 5 reserved names, and 3 redirections: 255.255.255.255, ff02::1, and fe80::1%lo0, which
        // Darwin's inet_pton accepts as an address with a scope. Either way it is never followed.
        #expect(result.skippedEntries == 8)
    }

    @Test func neverFollowsARedirection() {
        let result = HostsListParser.parse("203.0.113.7 bank.example.com\n192.168.1.1 router.example.com\n0.0.0.0 ok.example.com\n")
        #expect(result.domains == ["ok.example.com"])
        #expect(result.skippedEntries == 2)
    }

    @Test func readsPlainDomainLists() {
        let result = HostsListParser.parse("# EasyPrivacy\nmetrics.example.com\r\nPixel.Example.org\n\n  spaced.example.net  \n")
        #expect(result.domains == ["metrics.example.com", "pixel.example.org", "spaced.example.net"])
        #expect(result.invalidLines == 0)
    }

    @Test func rejectsMalformedLines() {
        let lines = [
            "0.0.0.0",                          // no name
            "two words.example.com",            // two tokens without an address
            "0.0.0.0 *.wild.example.com",       // wildcards mean nothing in a hosts file
            "0.0.0.0 -bad.example.com",
            "0.0.0.0 bad..example.com",
            "0.0.0.0 under/score.example.com",
            "0.0.0.0 " + String(repeating: "a", count: 64) + ".com",
            "0.0.0.0 " + String(repeating: "a.", count: 600) + "com",  // longer than the line limit
            "||ads.example.com^",               // Adblock syntax
            "0.0.0.0 ♥.example.com",            // not a letter
        ]
        let result = HostsListParser.parse(lines.joined(separator: "\n"))
        #expect(result.domains.isEmpty)
        #expect(result.invalidLines == lines.count)
    }

    @Test func cannotInjectHostsLines() {
        // Whatever the input, an output name is one token of letters, digits, '-', '_' and dots.
        let hostile = "0.0.0.0 evil.example.com\u{0B}0.0.0.0\n0.0.0.0 a.example.com\u{0}b\n0.0.0.0 x.example.com\u{2028}y.example.com\n"
        let result = HostsListParser.parse(hostile)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        for domain in result.domains {
            #expect(domain.allSatisfy(allowed.contains), "\(domain)")
        }
    }

    @Test func convertsInternationalNamesToPunycode() {
        let result = HostsListParser.parse("0.0.0.0 bücher.example\n0.0.0.0 MÜNCHEN.de\nпример.испытание\n0.0.0.0 xn--tda.example\n")
        #expect(result.domains == ["xn--bcher-kva.example", "xn--e1afmkfd.xn--80akhbyknj4f", "xn--mnchen-3ya.de", "xn--tda.example"])
    }

    @Test func punycodeMatchesRFC3492() {
        #expect(Punycode.encode("bücher") == "bcher-kva")
        #expect(Punycode.encode("münchen") == "mnchen-3ya")
        #expect(Punycode.encode("faß") == "fa-hia")
        #expect(Punycode.encode("ü") == "tda")
        #expect(Punycode.encode("español") == "espaol-zwa")
        #expect(Punycode.encode("日本語") == "wgv71a119e")
        #expect(IDNA.toASCII("Bücher.Example") == "xn--bcher-kva.example")
        #expect(IDNA.toASCII("☃.example") == nil)
    }

    @Test func skipsTheHostsHectorDownloadsFrom() {
        let result = HostsListParser.parse("0.0.0.0 raw.githubusercontent.com\n0.0.0.0 download.db-ip.com\n0.0.0.0 ads.example.com\n")
        #expect(result.domains == ["ads.example.com"])
        #expect(result.skippedEntries == 2)
    }

    @Test func stopsAtTheDomainLimit() {
        let text = (0..<20).map { "0.0.0.0 host\($0).example.com" }.joined(separator: "\n")
        let result = HostsListParser.parse(text, maximumDomains: 10)
        #expect(result.domains.count == 10)
        #expect(result.exceededLimit)
        // Duplicates do not count towards the limit.
        let duplicates = String(repeating: "0.0.0.0 same.example.com\n", count: 50)
        #expect(!HostsListParser.parse(duplicates, maximumDomains: 10).exceededLimit)
    }

    @Test func refusesDataThatIsNotUTF8() {
        let result = HostsListParser.parse(Data([0x30, 0x2E, 0xFF, 0xFE, 0x0A]))
        #expect(result.domains.isEmpty)
        #expect(result.invalidLines == 1)
    }

    @Test func ignoresAByteOrderMark() {
        #expect(HostsListParser.parse("\u{FEFF}0.0.0.0 bom.example.com\n").domains == ["bom.example.com"])
    }
}

@Suite struct HostsListCatalogTests {
    @Test func catalogURLsAreFixedHTTPS() {
        #expect(!HostsListCatalog.all.isEmpty)
        #expect(Set(HostsListCatalog.all.map(\.id)).count == HostsListCatalog.all.count)
        for source in HostsListCatalog.all {
            #expect(source.url.scheme == "https", "\(source.id)")
            #expect(HostsListCatalog.isIdentifier(source.id), "\(source.id)")
            #expect(source.minimumDomains > 0)
            #expect(HostsListCatalog.protectedHosts.contains(source.url.host() ?? ""))
        }
        #expect(HostsListCatalog.source("stevenblack-unified")?.url.absoluteString == "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")
        // Hosts format, which lists subdomains explicitly; the wildcard format would under-block.
        #expect(HostsListCatalog.source("hagezi-light")?.url.absoluteString == "https://raw.githubusercontent.com/hagezi/dns-blocklists-legacy/main/hosts/light.txt")
        // Normal and Pro exceed the per-list bound in hosts format.
        #expect(HostsListCatalog.source("hagezi-multi") == nil && HostsListCatalog.source("hagezi-pro") == nil)
        // Off by default, like every list.
        #expect(Blocklist().hostsLists.isEmpty)
    }

    @Test func identifiersHaveAStrictShape() {
        for bad in ["", "UPPER", "../etc", "a/b", "a b", "a.b", String(repeating: "a", count: 65)] {
            #expect(!HostsListCatalog.isIdentifier(bad), "\(bad)")
        }
        #expect(HostsListCatalog.isIdentifier("future-list-2"))
    }

    @Test func refusesImplausibleDownloads() throws {
        let source = HostsListSource(id: "test", name: "Test", summary: "", url: URL(string: "https://lists.example/hosts")!,
                                     homepage: URL(string: "https://lists.example")!, license: "", minimumDomains: 3)
        let good = Data("0.0.0.0 a.example.com\n0.0.0.0 b.example.com\n0.0.0.0 c.example.com\n".utf8)
        #expect(try HostsListDownloader.validate(good, for: source).domains.count == 3)

        let errorPage = Data("<html><body>404: Not Found</body></html>\n".utf8)
        #expect(throws: HostsListDownloader.DownloadError.implausible(domains: 0, minimum: 3)) {
            try HostsListDownloader.validate(errorPage, for: source)
        }
        #expect(throws: HostsListDownloader.DownloadError.notText) {
            try HostsListDownloader.validate(Data([0xFF, 0xFE, 0x00]), for: source)
        }
    }

    @Test func validatorsAreShortAndPrintable() {
        #expect(HostsListDownloader.validator(#""3e5c311e""#) == #""3e5c311e""#)
        #expect(HostsListDownloader.validator("a\r\nInjected: yes") == nil)
        #expect(HostsListDownloader.validator(String(repeating: "a", count: 300)) == nil)
        #expect(HostsListDownloader.validator("") == nil)
    }

    @Test func refreshesWeeklyAndRetriesLater() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HostsListState(id: "x").isDue(at: now))
        let fresh = HostsListState(id: "x", checkedAt: now.addingTimeInterval(-3_600), attemptedAt: now.addingTimeInterval(-3_600))
        #expect(!fresh.isDue(at: now))
        let old = HostsListState(id: "x", checkedAt: now.addingTimeInterval(-8 * 86_400), attemptedAt: now.addingTimeInterval(-8 * 86_400))
        #expect(old.isDue(at: now))
        let justFailed = HostsListState(id: "x", checkedAt: nil, attemptedAt: now.addingTimeInterval(-600), lastError: "timeout")
        #expect(!justFailed.isDue(at: now))
        let failedLongAgo = HostsListState(id: "x", checkedAt: nil, attemptedAt: now.addingTimeInterval(-7 * 3_600), lastError: "timeout")
        #expect(failedLongAgo.isDue(at: now))
    }
}

@Suite struct HostsListBlocklistTests {
    static let unified = HostsListCatalog.stevenBlackUnified.id
    static let privacy = HostsListCatalog.easyPrivacy.id

    @Test func blocklistsWithoutListsStillDecode() throws {
        // A 0.3 blocklist file: no "hostsLists" key.
        let old = Data(#"{"schemaVersion":1,"rules":[],"blockedCountries":["CN"]}"#.utf8)
        let blocklist = try JSONDecoder.hector.decode(Blocklist.self, from: old)
        #expect(blocklist.hostsLists.isEmpty)
        #expect(blocklist.blockedCountries == ["CN"])
        #expect(Blocklist().hostsLists.isEmpty)
    }

    @Test func listsRoundTripSorted() throws {
        let original = Blocklist(hostsLists: [Self.unified, Self.privacy])
        let data = try JSONEncoder.hector.encode(original)
        #expect(String(decoding: data, as: UTF8.self).contains(#""hostsLists" : [\#n    "easyprivacy",\#n    "stevenblack-unified"\#n  ]"#))
        let decoded = try JSONDecoder.hector.decode(Blocklist.self, from: data)
        #expect(decoded == original)
        #expect(decoded != Blocklist())
    }

    @Test func malformedIdentifiersAreRejectedWhenDecoding() {
        for bad in [#"["../../etc/passwd"]"#, #"["A"]"#, #"[""]"#, #"["a\nb"]"#] {
            let json = Data(#"{"schemaVersion":1,"rules":[],"blockedCountries":[],"hostsLists":\#(bad)}"#.utf8)
            #expect(throws: DecodingError.self, "\(bad)") { try JSONDecoder.hector.decode(Blocklist.self, from: json) }
        }
    }

    @Test func theHelperOnlyAcceptsCatalogLists() throws {
        #expect(throws: Never.self) { try HelperLimits.validate(Blocklist(hostsLists: [Self.unified])) }
        // Well formed but unknown: it decodes (a newer app may know it) but the helper refuses it.
        let json = Data(#"{"schemaVersion":1,"rules":[],"blockedCountries":[],"hostsLists":["my-own-list"]}"#.utf8)
        let blocklist = try JSONDecoder.hector.decode(Blocklist.self, from: json)
        #expect(throws: HelperLimits.Violation.self) { try HelperLimits.validate(blocklist) }
        let compiled = RuleCompiler.compile(blocklist, geo: nil, lists: ["my-own-list": ["ads.example.com"]])
        #expect(compiled.listDomains.isEmpty)
        #expect(compiled.warnings.contains { $0.contains("my-own-list") })
    }

    @Test func requestsCarryIdentifiersOnly() throws {
        let request = HelperRequest.apply(Blocklist(hostsLists: [Self.unified]), authorization: Data([1, 2]))
        let data = try JSONEncoder.hectorWire.encode(request)
        #expect(data.count < 300)
        let refresh = try JSONEncoder.hectorWire.encode(HelperRequest.refreshHostsLists(authorization: Data([3])))
        guard case .refreshHostsLists(let authorization) = try JSONDecoder.hector.decode(HelperRequest.self, from: refresh) else {
            Issue.record("Decoded the wrong request")
            return
        }
        #expect(authorization == Data([3]))
    }

    @Test func statusFromAnOlderHelperHasNoLists() throws {
        let status = HelperStatus(version: "0.4.0", pfEnabled: true, anchorLoaded: true, appliedAt: nil, blocklist: nil,
                                  blockTableCount: 0, geoTableCount: 0, hostsDomainCount: 0, warnings: [])
        let encoded = try JSONEncoder.hectorWire.encode(status)
        let object = try JSONSerialization.jsonObject(with: encoded)
        var json = try #require(object as? [String: Any])
        json.removeValue(forKey: "listDomainCount")
        json.removeValue(forKey: "hostsLists")
        let decoded = try JSONDecoder.hector.decode(HelperStatus.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.hostsLists == nil)
        #expect(decoded.listDomainCount == nil)

        var current = status
        current.listDomainCount = 2
        current.hostsLists = [HostsListState(id: Self.unified, domainCount: 2, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        let roundTrip = try JSONDecoder.hector.decode(HelperStatus.self, from: JSONEncoder.hectorWire.encode(current))
        #expect(roundTrip == current)
    }
}

@Suite struct HostsListCompilerTests {
    static let unified = HostsListCatalog.stevenBlackUnified.id
    static let privacy = HostsListCatalog.easyPrivacy.id

    @Test func mergesListsWithoutThePersonalDomains() {
        let blocklist = Blocklist(rules: [Rule(target: RuleTarget("ads.example.com")!)], hostsLists: [Self.unified, Self.privacy])
        let lists = [
            Self.unified: ["ads.example.com", "malware.example.net", "shared.example.org"],
            Self.privacy: ["shared.example.org", "pixel.example.com"],
        ]
        let compiled = RuleCompiler.compile(blocklist, geo: nil, lists: lists)
        #expect(compiled.hostsDomains == ["ads.example.com"])
        #expect(compiled.listDomains == ["malware.example.net", "pixel.example.com", "shared.example.org"])
        #expect(compiled.listDomainCounts == [Self.unified: 3, Self.privacy: 2])
        #expect(compiled.warnings.isEmpty)
    }

    @Test func ignoresListsThatAreNotSubscribed() {
        let compiled = RuleCompiler.compile(Blocklist(), geo: nil, lists: [Self.unified: ["ads.example.com"]])
        #expect(compiled.listDomains.isEmpty)
        #expect(compiled.listDomainCounts.isEmpty)
    }

    @Test func warnsAboutListsNotDownloadedYet() {
        let compiled = RuleCompiler.compile(Blocklist(hostsLists: [Self.unified]), geo: nil, lists: [:])
        #expect(compiled.listDomains.isEmpty)
        #expect(compiled.warnings.count == 1)
    }

    @Test func checksEveryCachedNameAgain() {
        let damaged = ["localhost", "ok.example.com", "bad name", "0.0.0.0 x.example", "UPPER.example.com", "raw.githubusercontent.com", "*.wild.example"]
        let compiled = RuleCompiler.compile(Blocklist(hostsLists: [Self.unified]), geo: nil, lists: [Self.unified: damaged])
        #expect(compiled.listDomains == ["ok.example.com"])
    }

    @Test func capsTheTotalNumberOfListDomains() {
        var warnings: [String] = []
        let domains = (0..<10).map { "host\($0).example.com" }
        let result = RuleCompiler.compileLists([Self.unified], lists: [Self.unified: domains], personal: [], warnings: &warnings, limit: 4)
        #expect(result.domains.count == 4)
        #expect(warnings.count == 1)
    }

    @Test func listDomainsGoAfterTheMarkerInTheManagedSection() {
        let stock = "127.0.0.1\tlocalhost\n"
        let rendered = HostsFile.render(existing: stock, domains: ["mine.example"], listDomains: ["a.list.example", "b.list.example"])
        #expect(rendered.hasPrefix(stock))
        #expect(rendered.contains("0.0.0.0 mine.example\n:: mine.example\n\(HostsFile.listsMarker)\n0.0.0.0 a.list.example\n"))
        #expect(HostsFile.managedDomains(in: rendered) == ["a.list.example", "b.list.example", "mine.example"])
        #expect(HostsFile.render(existing: rendered, domains: ["mine.example"], listDomains: ["a.list.example", "b.list.example"]) == rendered)
        #expect(HostsFile.render(existing: rendered, domains: [], listDomains: []) == stock)

        let listsOnly = HostsFile.render(existing: stock, domains: [], listDomains: ["a.list.example"])
        #expect(HostsFile.managedDomains(in: listsOnly) == ["a.list.example"])
        #expect(!HostsFile.render(existing: stock, domains: ["mine.example"]).contains(HostsFile.listsMarker))
    }
}
