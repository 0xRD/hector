import Foundation
import Testing
@testable import HectorCore

@Suite struct AdblockListParserTests {
    /// The shapes found in OISD, HaGeZi and the AdGuard DNS filter.
    static let sample = """
    [Adblock Plus]
    ! Title: oisd small
    ! Syntax: Adblock Plus Filter List
    # a comment in hosts style
    ||ads.example.com^
    ||Tracker.Example.NET^
    ||ads.example.com^
    ||important.example.org^$important
    @@||ad.allowed.example.com^
    @@||kept.example.org^$important
    ||retired.example.com^
    ||retired.example.com^$badfilter
    ||pixel.example.com^$third-party
    ||ad-host-backup-*.example.com^
    ||no-caret.example.com
    ||path.example.com^/banner
    .bbelements.example.com^
    /^139\\.45\\.197\\.2(4[0-9]|5[0-4]):/
    example.com##.banner
    ||ip.example.com:8080^
    ||192.0.2.7^
    ||bad..example.com^
    ||-bad.example.com^
    ||localhost^
    ||printer.local^
    ||raw.githubusercontent.com^
    0.0.0.0 hosts-line.example.com
    """

    @Test func readsBlockRulesAsSubtrees() {
        let result = AdblockListParser.parse(Self.sample)
        #expect(result.subtrees == ["ads.example.com", "important.example.org", "tracker.example.net"])
        #expect(result.exact.isEmpty)
        #expect(result.domainCount == 3)
        #expect(!result.exceededLimit)
    }

    @Test func readsExceptions() {
        let result = AdblockListParser.parse(Self.sample)
        #expect(result.exceptions == ["ad.allowed.example.com", "kept.example.org"])
    }

    @Test func badfilterCancelsTheSameRule() {
        let result = AdblockListParser.parse(Self.sample)
        #expect(!result.subtrees.contains("retired.example.com"))
        // In either order.
        #expect(AdblockListParser.parse("||a.example.com^$badfilter\n||a.example.com^\n||b.example.com^").subtrees == ["b.example.com"])
    }

    @Test func countsUnsupportedInvalidAndSkippedLines() {
        let result = AdblockListParser.parse(Self.sample)
        // $third-party, *, no ^, a path, a leading dot, a regex, a cosmetic rule, a port, an
        // address, a hosts line.
        #expect(result.unsupportedRules == 10)
        #expect(result.invalidLines == 2)
        // localhost, a .local name, a host Hector downloads from.
        #expect(result.skippedEntries == 3)
    }

    @Test func convertsInternationalNames() {
        let result = AdblockListParser.parse("||Bücher.example^\n")
        #expect(result.subtrees == ["xn--bcher-kva.example"])
    }

    @Test func handlesLineBreaksBOMAndSpaces() {
        let result = AdblockListParser.parse("\u{FEFF}||a.example.com^\r\n  ||b.example.com^  \r\n\n||c.example.com^")
        #expect(result.subtrees == ["a.example.com", "b.example.com", "c.example.com"])
        #expect(result.invalidLines == 0)
        #expect(result.unsupportedRules == 0)
    }

    @Test func stopsAtTheLimit() {
        let text = (0..<50).map { "||n\($0).example.com^" }.joined(separator: "\n")
        let result = AdblockListParser.parse(text, maximumDomains: 10)
        #expect(result.exceededLimit)
        #expect(result.subtrees.count == 10)
    }

    @Test func refusesOverlongLines() {
        let result = AdblockListParser.parse("||" + String(repeating: "a.", count: 600) + "com^\n||ok.example.com^")
        #expect(result.invalidLines == 1)
        #expect(result.subtrees == ["ok.example.com"])
    }
}

@Suite struct DomainListFormatTests {
    @Test func hostsListsBlockExactNames() {
        let result = DomainListFormat.hosts.parse(Data("0.0.0.0 ads.example.com\nplain.example.org\n".utf8))
        #expect(result.exact == ["ads.example.com", "plain.example.org"])
        #expect(result.subtrees.isEmpty)
    }

    @Test func wildcardListsBlockSubtrees() {
        let oisd = """
        # Syntax: Domains (wildcards) without *.
        # Entry: "example.com" should block access to "example.com" and "subdomain.example.com"
        0-02.example
        000webhostapp.example
        """
        let result = DomainListFormat.wildcardDomains.parse(Data(oisd.utf8))
        #expect(result.subtrees == ["0-02.example", "000webhostapp.example"])
        #expect(result.exact.isEmpty)
        let policy = DomainPolicy(lists: DomainSet(exact: result.exact, subtrees: result.subtrees))
        #expect(policy.blocks("user1.000webhostapp.example"))
    }

    @Test func adblockListsGoThroughTheAdblockParser() {
        let result = DomainListFormat.adblock.parse(Data("||ads.example.com^\n@@||ok.ads.example.com^\n".utf8))
        #expect(result.subtrees == ["ads.example.com"])
        #expect(result.exceptions == ["ok.ads.example.com"])
    }

    @Test func refusesDataThatIsNotUTF8() {
        let result = DomainListFormat.adblock.parse(Data([0xFF, 0xFE, 0xFD]))
        #expect(result.domainCount == 0)
        #expect(result.invalidLines == 1)
    }
}
