import Foundation

/// What Hector has already seen of something that can appear later (persistence items, apps
/// making connections, keyboard taps), so that only what is new gets announced.
///
/// Keys are kept per group. The first time a group is admitted, everything in it is taken as
/// known without being announced: turning a watch on must not report every item already there.
public struct KnownSet: Codable, Equatable, Sendable {
    /// Groups admitted at least once.
    public private(set) var groups: Set<String> = []
    public private(set) var keys: [String: Set<String>] = [:]

    /// Past this many keys in one group, the group keeps only what was just seen, so a stream of
    /// new keys cannot grow the file without bound.
    public static let maximumKeysPerGroup = 20_000

    public init() {}

    /// Records `current` as seen in `group` and returns the keys that were not known, in their
    /// order in `current`. Returns nothing the first time `group` is admitted.
    public mutating func admit(_ current: [String], group: String) -> [String] {
        var known = keys[group] ?? []
        let isFirst = !groups.contains(group)
        var fresh: [String] = []
        for key in current where !known.contains(key) {
            known.insert(key)
            if !isFirst { fresh.append(key) }
        }
        if known.count > Self.maximumKeysPerGroup {
            // Keep what was just seen; forget the rest.
            known = Set(current.suffix(Self.maximumKeysPerGroup))
        }
        keys[group] = known
        groups.insert(group)
        return fresh
    }

    public func isKnown(_ key: String, group: String) -> Bool { keys[group]?.contains(key) == true }

    /// Forgets a group: its next admission is a first one again.
    public mutating func reset(group: String) {
        groups.remove(group)
        keys[group] = nil
    }
}

/// A `KnownSet` kept in a JSON file. A missing or damaged file starts empty.
public struct KnownSetFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `~/Library/Application Support/Hector/<name>.json`.
    public init(named name: String) {
        url = LegacyMigration.userDataDirectory.appending(path: "\(name).json")
    }

    public func load() -> KnownSet {
        guard let data = try? Data(contentsOf: url), data.count < 16 << 20,
              let set = try? JSONDecoder().decode(KnownSet.self, from: data) else { return KnownSet() }
        return set
    }

    public func save(_ set: KnownSet) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(set) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
