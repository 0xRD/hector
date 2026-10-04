import Foundation

/// Decides, for the local resolver, whether a name is blocked, and by which rule.
///
/// Four layers are checked in a fixed order and the first that covers the name decides:
///
/// 1. the user's **allowlist** ("unblock this"), which wins over everything;
/// 2. the user's **personal rules**;
/// 3. **exceptions** published inside subscribed lists (`@@||name^`), which only undo list entries;
/// 4. the **subscribed lists**.
///
/// A name no layer covers is forwarded upstream. Within a layer, an entry covers its own name and,
/// when it was added with its subdomains, every name below it.
public struct DomainPolicy: Sendable {
    public enum Layer: String, Codable, Sendable, CaseIterable {
        case allowlist
        case personalRule
        case listException
        case list

        public var blocks: Bool {
            switch self {
            case .allowlist, .listException: false
            case .personalRule, .list: true
            }
        }
    }

    public struct Decision: Hashable, Sendable {
        public let layer: Layer
        /// The entry that covered the name (the name itself, or a parent).
        public let entry: String
        public let includesSubdomains: Bool

        public var blocks: Bool { layer.blocks }

        init(_ layer: Layer, _ match: DomainSet.Match) {
            self.layer = layer
            entry = match.entry
            includesSubdomains = match.includesSubdomains
        }
    }

    public let allowlist: DomainSet
    public let personalRules: DomainSet
    public let listExceptions: DomainSet
    public let lists: DomainSet

    public init(allowlist: DomainSet = .empty, personalRules: DomainSet = .empty, listExceptions: DomainSet = .empty,
                lists: DomainSet = .empty) {
        self.allowlist = allowlist
        self.personalRules = personalRules
        self.listExceptions = listExceptions
        self.lists = lists
    }

    public static let empty = DomainPolicy()

    /// The layer that decides for `name`, or `nil` when none covers it (forward it).
    public func decision(for name: String) -> Decision? {
        // One lookup per layer, in order, without building anything per query.
        if let match = allowlist.match(name) { return Decision(.allowlist, match) }
        if let match = personalRules.match(name) { return Decision(.personalRule, match) }
        if let match = listExceptions.match(name) { return Decision(.listException, match) }
        if let match = lists.match(name) { return Decision(.list, match) }
        return nil
    }

    /// Whether the resolver should answer `name` as blocked.
    public func blocks(_ name: String) -> Bool {
        decision(for: name)?.blocks ?? false
    }

    /// Whether a query for `name` should be blocked: a name that is not a plain host name (bytes
    /// other than letters, digits, `-` and `_`) is never matched and goes upstream unchanged.
    public func blocks(_ name: DNSName) -> Bool {
        guard let text = name.text else { return false }
        return blocks(text)
    }

    /// Entries and bytes held, for the status and the memory budget.
    public var count: Int {
        allowlist.count + personalRules.count + listExceptions.count + lists.count
    }

    public var byteCount: Int {
        allowlist.byteCount + personalRules.byteCount + listExceptions.byteCount + lists.byteCount
    }
}
