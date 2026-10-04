import Foundation
import Testing
@testable import HectorCore

@Suite struct DomainSetTests {
    static let set = DomainSet(exact: ["exact.example.com", "Tracker.Example.NET."], subtrees: ["doubleclick.net", "ads.example.org"])

    @Test func matchesExactNamesAlone() {
        #expect(Self.set.match("exact.example.com") == DomainSet.Match(entry: "exact.example.com", includesSubdomains: false))
        #expect(!Self.set.contains("sub.exact.example.com"))
        #expect(!Self.set.contains("example.com"))
    }

    @Test func matchesSubtreesAndTheirApex() {
        #expect(Self.set.contains("doubleclick.net"))
        #expect(Self.set.match("stats.g.doubleclick.net") == DomainSet.Match(entry: "doubleclick.net", includesSubdomains: true))
        #expect(Self.set.contains("ads.example.org"))
        #expect(Self.set.contains("x.ads.example.org"))
        #expect(!Self.set.contains("example.org"))
    }

    @Test func matchesOnLabelBoundariesOnly() {
        #expect(!Self.set.contains("notdoubleclick.net"))
        #expect(!Self.set.contains("doubleclick.network"))
        #expect(!Self.set.contains("net"))
        #expect(!Self.set.contains(""))
    }

    @Test func ignoresCaseAndTrailingDot() {
        #expect(Self.set.contains("tracker.example.net"))
        #expect(Self.set.contains("WWW.DoubleClick.NET."))
    }

    @Test func keepsTheWiderMeaningOfADuplicate() {
        let set = DomainSet(exact: ["a.example.com", "b.example.com", "a.example.com"], subtrees: ["a.example.com"])
        #expect(set.count == 2)
        #expect(set.contains("x.a.example.com"))
        #expect(set.entries.map(\.name) == ["a.example.com", "b.example.com"])
        #expect(set.entries.map(\.includesSubdomains) == [true, false])
    }

    @Test func returnsTheMostSpecificEntry() {
        let set = DomainSet(exact: [], subtrees: ["example.com", "ads.example.com"])
        #expect(set.match("x.ads.example.com")?.entry == "ads.example.com")
        #expect(set.match("x.example.com")?.entry == "example.com")

        // An exact parent does not hide a wider grandparent.
        let mixed = DomainSet(exact: ["ads.example.com"], subtrees: ["example.com"])
        #expect(mixed.match("x.ads.example.com")?.entry == "example.com")
        #expect(mixed.match("ads.example.com") == DomainSet.Match(entry: "ads.example.com", includesSubdomains: false))
    }

    @Test func dropsEmptyAndOverlongNames() {
        let set = DomainSet(exact: ["", ".", String(repeating: "a", count: 254)], subtrees: [])
        #expect(set.isEmpty)
        #expect(!DomainSet.empty.contains("example.com"))
    }

    /// Against a `Set<String>` model, on enough names to cross many 64-bit words of flags.
    @Test func agreesWithASimpleModel() {
        var exact = Set<String>()
        var subtrees = Set<String>()
        for index in 0..<5_000 {
            if index % 3 == 0 {
                subtrees.insert("s\(index).example\(index % 17).com")
            } else {
                exact.insert("e\(index).example\(index % 17).com")
            }
        }
        let set = DomainSet(exact: exact, subtrees: subtrees)
        #expect(set.count == exact.count + subtrees.count)
        for index in 0..<5_000 {
            let name = index % 3 == 0 ? "s\(index).example\(index % 17).com" : "e\(index).example\(index % 17).com"
            #expect(set.contains(name))
            #expect(set.contains("deep.x." + name) == (index % 3 == 0))
            #expect(!set.contains("s\(index)x.example\(index % 17).com"))
        }
    }

    @Test func staysCompact() {
        let names = (0..<10_000).map { "tracker-\($0).analytics.example.com" }
        let set = DomainSet(exact: names, subtrees: [])
        let textBytes = names.reduce(0) { $0 + $1.utf8.count }
        // The names themselves, 4 bytes of offset each, and a bit of flags.
        #expect(set.byteCount <= textBytes + 4 * 10_001 + 8 * 157)
    }
}

@Suite struct DomainPolicyTests {
    static let policy = DomainPolicy(
        allowlist: DomainSet(exact: ["unblocked.ads.example.com"], subtrees: ["cdn.example.net"]),
        personalRules: DomainSet(exact: [], subtrees: ["mine.example.com", "cdn.example.net"]),
        listExceptions: DomainSet(exact: [], subtrees: ["ok.example.com", "mine.example.com"]),
        lists: DomainSet(exact: [], subtrees: ["example.com", "example.net"])
    )

    @Test func allowlistWinsOverEverything() {
        #expect(Self.policy.decision(for: "unblocked.ads.example.com")?.layer == .allowlist)
        #expect(!Self.policy.blocks("unblocked.ads.example.com"))
        // An exact allow entry unblocks that name only.
        #expect(Self.policy.blocks("x.unblocked.ads.example.com"))
        // A subtree allow entry wins over a personal rule for the same subtree.
        #expect(!Self.policy.blocks("img.cdn.example.net"))
    }

    @Test func personalRulesWinOverListExceptions() {
        #expect(Self.policy.decision(for: "a.mine.example.com")?.layer == .personalRule)
        #expect(Self.policy.blocks("a.mine.example.com"))
    }

    @Test func listExceptionsUndoListEntries() {
        #expect(Self.policy.decision(for: "www.ok.example.com")?.layer == .listException)
        #expect(!Self.policy.blocks("www.ok.example.com"))
        #expect(Self.policy.decision(for: "other.example.com") == DomainPolicy.Decision(.list, DomainSet.Match(entry: "example.com", includesSubdomains: true)))
    }

    @Test func forwardsWhatNoLayerCovers() {
        #expect(Self.policy.decision(for: "example.org") == nil)
        #expect(!Self.policy.blocks("example.org"))
        #expect(!DomainPolicy.empty.blocks("example.com"))
    }

    @Test func neverMatchesNamesThatAreNotHostNames() {
        let odd = DNSName(labels: [Array("a b".utf8), Array("example".utf8), Array("com".utf8)])!
        #expect(!Self.policy.blocks(odd))
        #expect(Self.policy.blocks(DNSName("A.Example.COM")!))
    }
}
