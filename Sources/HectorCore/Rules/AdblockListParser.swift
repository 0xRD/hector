import Foundation

/// The syntax of a downloaded list, and what each of its names means.
public enum DomainListFormat: String, Codable, Sendable, CaseIterable {
    /// `0.0.0.0 name` lines or one name per line; each name blocks itself only (StevenBlack,
    /// hMirror's EasyPrivacy, Peter Lowe's hosts format).
    case hosts
    /// One name per line, each blocking the name and all its subdomains (OISD `domainswild2`,
    /// HaGeZi `wildcard/*-onlydomains.txt`, 1Hosts `domains.wildcards`). Only a resolver can
    /// honor that; /etc/hosts would block the listed names alone.
    case wildcardDomains
    /// Adblock-style DNS rules: `||name^` blocks the name and its subdomains, `@@||name^` is an
    /// exception (OISD, HaGeZi `adblock/`, AdGuard DNS filter, 1Hosts `adblock.txt`).
    case adblock

    /// Parses `data` in this format. Data that is not valid UTF-8 parses to nothing, with one
    /// invalid line.
    public func parse(_ data: Data, maximumDomains: Int = HostsListCatalog.maximumDomainsPerList,
                      protectedHosts: Set<String> = HostsListCatalog.protectedHosts) -> DomainListParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return DomainListParseResult(exact: [], subtrees: [], exceptions: [], invalidLines: 1, unsupportedRules: 0,
                                         skippedEntries: 0, exceededLimit: false)
        }
        switch self {
        case .hosts, .wildcardDomains:
            let hosts = HostsListParser.parse(text, maximumDomains: maximumDomains, protectedHosts: protectedHosts)
            let wildcard = self == .wildcardDomains
            return DomainListParseResult(exact: wildcard ? [] : hosts.domains, subtrees: wildcard ? hosts.domains : [],
                                         exceptions: [], invalidLines: hosts.invalidLines, unsupportedRules: 0,
                                         skippedEntries: hosts.skippedEntries, exceededLimit: hosts.exceededLimit)
        case .adblock:
            return AdblockListParser.parse(text, maximumDomains: maximumDomains, protectedHosts: protectedHosts)
        }
    }
}

/// The result of parsing a list for the resolver.
public struct DomainListParseResult: Sendable, Equatable {
    /// Names that block themselves only. Lowercased ASCII (punycode), sorted, without duplicates,
    /// like every list below.
    public var exact: [String]
    /// Names that block themselves and all their subdomains.
    public var subtrees: [String]
    /// Names the list itself unblocks, with their subdomains (`@@||name^`).
    public var exceptions: [String]
    /// Malformed lines and lines with an invalid name.
    public var invalidLines: Int
    /// Well-formed rules a DNS resolver cannot honor or that Hector does not support: paths,
    /// wildcards, regular expressions, cosmetic rules, unknown modifiers.
    public var unsupportedRules: Int
    /// Reserved names and protected hosts, left out on purpose.
    public var skippedEntries: Int
    /// The list had more names than allowed; the lists stop at the limit.
    public var exceededLimit: Bool

    /// Blocking names, both kinds.
    public var domainCount: Int { exact.count + subtrees.count }
}

/// A strict parser for the DNS subset of the Adblock Plus syntax, as DNS blocklists publish it.
///
/// Accepted, everything else is counted and dropped:
/// - `||name^`: block the name and its subdomains;
/// - `@@||name^`: an exception, which undoes the list's own entries for the name and its
///   subdomains (personal rules and the allowlist are separate, see `DomainPolicy`);
/// - the `$important` modifier on either, which changes nothing here;
/// - `||name^$badfilter`, which cancels the identical rule without the modifier (AdGuard uses it
///   to retire rules inherited from another list);
/// - comments (`!`, `#`), the `[Adblock Plus]` header and blank lines.
///
/// Every name goes through the same checks as hosts lists (`HostsListParser.normalizedHost`):
/// letters, digits, `-` and `_`, punycode for international names, and reserved or protected
/// names are skipped. Lines with `*`, a path, a regular expression, an IP address, a leading `.`
/// or `|`, no trailing `^`, or any other modifier (`$third-party`, `$client`, `$dnstype`…) are unsupported:
/// honoring them half-way would block more or less than the list means.
public enum AdblockListParser {
    private static let blockPrefix = "||"
    private static let exceptionPrefix = "@@||"

    private enum Rule {
        case block(String)
        case exception(String)
        case cancel(String)
    }

    private enum Entry {
        case rule(Rule)
        case ignored
        case invalid
        case unsupported
        case skipped
    }

    public static func parse(_ text: String, maximumDomains: Int = HostsListCatalog.maximumDomainsPerList,
                             protectedHosts: Set<String> = HostsListCatalog.protectedHosts) -> DomainListParseResult {
        var blocked = Set<String>()
        var exceptions = Set<String>()
        var cancelled = Set<String>()
        var invalid = 0
        var unsupported = 0
        var skipped = 0
        var exceeded = false

        let body: Substring = text.hasPrefix("\u{FEFF}") ? text.dropFirst() : text[...]
        lines: for line in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard line.utf8.count <= HostsListCatalog.maximumLineLength else {
                invalid += 1
                continue
            }
            switch entry(for: line, protectedHosts: protectedHosts) {
            case .ignored:
                break
            case .invalid:
                invalid += 1
            case .unsupported:
                unsupported += 1
            case .skipped:
                skipped += 1
            case .rule(.block(let host)):
                if blocked.contains(host) { continue }
                guard blocked.count + exceptions.count < maximumDomains else {
                    exceeded = true
                    break lines
                }
                blocked.insert(host)
            case .rule(.exception(let host)):
                if exceptions.contains(host) { continue }
                guard blocked.count + exceptions.count < maximumDomains else {
                    exceeded = true
                    break lines
                }
                exceptions.insert(host)
            case .rule(.cancel(let host)):
                cancelled.insert(host)
            }
        }
        blocked.subtract(cancelled)
        return DomainListParseResult(exact: [], subtrees: blocked.sorted(), exceptions: exceptions.sorted(), invalidLines: invalid,
                                     unsupportedRules: unsupported, skippedEntries: skipped, exceededLimit: exceeded)
    }

    private static func entry(for rawLine: Substring, protectedHosts: Set<String>) -> Entry {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("!") || (line.hasPrefix("[") && line.hasSuffix("]")) {
            return .ignored
        }
        // `##` and `#@#` start cosmetic rules, which have no meaning for DNS; `#` alone a comment.
        if line.hasPrefix("##") || line.hasPrefix("#@#") || line.hasPrefix("#?#") { return .unsupported }
        if line.hasPrefix("#") { return .ignored }

        let isException = line.hasPrefix(exceptionPrefix)
        guard isException || line.hasPrefix(blockPrefix) else { return .unsupported }
        var rest = line.dropFirst(isException ? exceptionPrefix.count : blockPrefix.count)

        var modifiers: [Substring] = []
        if let dollar = rest.firstIndex(of: "$") {
            modifiers = rest[rest.index(after: dollar)...].split(separator: ",", omittingEmptySubsequences: false)
            rest = rest[..<dollar]
        }
        guard rest.hasSuffix("^"), rest.count > 1 else { return .unsupported }
        let name = rest.dropLast()
        // Wildcards, paths, ports and anything that is not a bare name.
        if name.contains(where: { "*/:|^?=&".contains($0) }) || name.hasPrefix(".") { return .unsupported }
        // `||203.0.113.7^` blocks answers that hold that address (AdGuard Home), not a name.
        if IPAddress(String(name)) != nil { return .unsupported }

        var cancels = false
        for modifier in modifiers {
            switch modifier {
            case "important": continue
            case "badfilter" where !isException: cancels = true
            default: return .unsupported
            }
        }

        guard let host = HostsListParser.normalizedHost(String(name)) else { return .invalid }
        if HostsListParser.isReserved(host) || protectedHosts.contains(host) { return .skipped }
        if cancels { return .rule(.cancel(host)) }
        return .rule(isException ? .exception(host) : .block(host))
    }
}
