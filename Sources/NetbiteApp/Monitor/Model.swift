import Foundation
import NetbiteCore

/// One remote endpoint an app talks to.
struct DestinationKey: Hashable, Sendable {
    let address: IPAddress
    let port: UInt16
    let transport: TransportProtocol

    var portLabel: String { "\(port)/\(transport.rawValue.uppercased())" }
}

/// Identifies a destination row: the same endpoint used by two apps is two rows.
struct DestinationRef: Hashable, Sendable {
    let appID: AppGroup.ID
    let key: DestinationKey
}

struct Destination: Identifiable, Hashable {
    let key: DestinationKey
    var id: DestinationKey { key }
    /// ISO country code from the GeoIP database; `nil` for private ranges or before it loads.
    var country: String?
    /// PTR name, filled in asynchronously.
    var hostname: String?
    var liveConnections: Int
    var tcpStates: [String]
    var firstSeen: Date
    var lastSeen: Date
    /// Live connection count per refresh, oldest first, at most `ConnectionMonitor.historyLength`.
    var activity: [Int]

    var isLive: Bool { liveConnections > 0 }
    var isLocal: Bool { key.address.isLocalOrPrivate }
    var title: String { hostname ?? key.address.description }
}

enum AppKind {
    /// Lives in a `.app` bundle outside /System.
    case app
    /// Daemons, command-line tools, system services.
    case system
}

/// Every process that belongs to one app (or one executable), with the destinations seen this session.
struct AppGroup: Identifiable {
    let id: String
    var name: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var executablePath: String?
    var kind: AppKind
    var processNames: Set<String>
    var pids: Set<Int32>
    var destinations: [DestinationKey: Destination]
    /// Total live connections per refresh.
    var activity: [Int]

    var liveCount: Int { destinations.values.reduce(0) { $0 + $1.liveConnections } }

    /// Live destinations first, then the most recently seen.
    var sortedDestinations: [Destination] {
        destinations.values.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.key.address < $1.key.address
        }
    }

    var identityLabel: String { bundleIdentifier ?? executablePath ?? name }
}

/// A destination together with the app that uses it, the unit the list and the map work with.
struct DestinationRow: Identifiable {
    let app: AppGroup
    let destination: Destination
    /// Set when the applied blocklist cuts this destination off.
    var blockReason: BlockReason?
    var id: DestinationRef { DestinationRef(appID: app.id, key: destination.key) }
    var isBlocked: Bool { blockReason != nil }
}

enum DestinationFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case live = "Live"
    case blocked = "Blocked"

    var id: String { rawValue }

    func includes(_ row: DestinationRow) -> Bool {
        switch self {
        case .all: true
        case .live: row.destination.isLive && !row.isBlocked
        case .blocked: row.isBlocked
        }
    }
}

enum Countries {
    private static let english = Locale(identifier: "en_US")

    /// Plain short names where the system's are long or political qualifiers get in the way of a list.
    private static let overrides = ["CN": "China", "HK": "Hong Kong", "MO": "Macao"]

    static func name(_ code: String?) -> String {
        guard let code else { return "Unknown" }
        return overrides[code] ?? english.localizedString(forRegionCode: code) ?? code
    }
}
