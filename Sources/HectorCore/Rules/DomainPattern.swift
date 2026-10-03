import Foundation

/// A host name to block, optionally with all of its subdomains (`*.example.com`).
public struct DomainPattern: Hashable, Sendable {
    /// Lowercased host without the `*.` prefix or trailing dot.
    public let host: String
    public let includesSubdomains: Bool

    public init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var wildcard = false
        if value.hasPrefix("*.") {
            wildcard = true
            value.removeFirst(2)
        }
        if value.hasSuffix(".") { value.removeLast() }
        guard Self.isValidHost(value) else { return nil }
        host = value
        includesSubdomains = wildcard
    }

    /// Built once: hosts lists validate hundreds of thousands of names.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, IPAddress(host) == nil else { return false }
        let allowed = Self.allowed
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.count)
                && label.allSatisfy(allowed.contains)
                && label.first != "-" && label.last != "-"
        }
    }
}

extension DomainPattern: CustomStringConvertible {
    public var description: String { includesSubdomains ? "*.\(host)" : host }
}
