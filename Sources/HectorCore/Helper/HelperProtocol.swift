import Foundation

public enum HectorVersion {
    /// The single version string of the app, the CLI and the helper. `scripts/bundle-app.sh` reads it.
    public static let current = "0.4.2"
}

/// Where the privileged helper lives once installed, and how to reach it.
public enum HelperPaths {
    public static let label = "io.github.0xrd.hectord"
    public static let socket = "/var/run/\(label).sock"
    public static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(label).plist"
    /// Root-owned data: the applied blocklist, pf files, the helper's GeoIP copy.
    public static let dataDirectory = "/Library/Application Support/Hector"
    public static let logFile = "/Library/Logs/Hector/hectord.log"
}

/// What Netbite 0.3 and earlier installed, before the app became Hector. Installing Hector's
/// helper replaces the old one (its applied blocklist carries over), and uninstalling removes both.
///
/// The pf anchor and the /etc/hosts section kept their names: Netbite is still the name of the
/// network module, and keeping them means rules survive the update without a gap.
public enum LegacyPaths {
    public static let helperLabel = "io.github.0xrd.netbited"
    public static let socket = "/var/run/\(helperLabel).sock"
    public static let installedBinary = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let dataDirectory = "/Library/Application Support/Netbite"
    public static let logDirectory = "/Library/Logs/Netbite"
    public static let authorizationRight = "io.github.0xrd.netbite.modify-firewall"
    /// Preferences, caches and saved state of Netbite.app.
    public static let bundleIdentifier = "io.github.0xrd.netbite"
    /// `~/Library/Application Support/Netbite`: blocklist draft, country database, VirusTotal cache.
    public static let userDataFolder = "Netbite"
    public static let keychainService = "io.github.0xrd.netbite.virustotal"
}

/// A request to the helper. One request per connection, as one line of JSON.
///
/// Requests that change the firewall carry an Authorization Services external form
/// (`HelperAuthorization.externalForm()`); read-only requests do not.
public enum HelperRequest: Codable, Sendable {
    case status
    /// Compile and enforce this blocklist (the helper recompiles it; nothing compiled is trusted).
    case apply(Blocklist, authorization: Data)
    /// Remove every Netbite pf rule and the managed /etc/hosts section, keeping the helper installed.
    case flush(authorization: Data)
    /// Download the subscribed hosts lists now (conditionally), and apply them if they changed.
    /// Carries no list and no URL: the helper refreshes the lists of the blocklist it enforces,
    /// from the built-in catalog. Helpers older than this case answer with a failure.
    case refreshHostsLists(authorization: Data)
    /// A socket snapshot taken as root, which includes system daemons.
    case snapshot
    /// Every running process as root sees it: arguments and sockets of every user included.
    case processes
    /// The output of `sfltool dumpbtm`, the login items and background tasks of every user. The
    /// tool asks for a password unless it runs as root.
    case backgroundTasks
    /// Who the helper is and what it can do (`HelperInfo`). Send it first: a helper older than
    /// this case cannot decode it and answers with a failure, which tells the client it faces a
    /// helper from before the handshake (`HelperInfo.legacy`).
    case hello

    /// The capability a request needs, to check it against `HelperInfo.capabilities` before sending.
    public var capability: HelperCapability {
        switch self {
        case .status: .status
        case .apply: .apply
        case .flush: .flush
        case .refreshHostsLists: .refreshHostsLists
        case .snapshot: .snapshot
        case .processes: .processes
        case .backgroundTasks: .backgroundTasks
        case .hello: .hello
        }
    }

    /// Requests that read or change the enforced rules. The helper runs them one at a time; the
    /// others (snapshots, processes, login items, hello) run alongside them.
    public var touchesRules: Bool {
        switch self {
        case .status, .apply, .flush, .refreshHostsLists: true
        case .snapshot, .processes, .backgroundTasks, .hello: false
        }
    }
}

/// One kind of request a helper understands.
public enum HelperCapability: String, Codable, CaseIterable, Sendable {
    case hello, status, snapshot, apply, flush, processes, backgroundTasks, refreshHostsLists
}

/// The helper's answer to `hello`.
public struct HelperInfo: Codable, Equatable, Sendable {
    /// Bumped when requests or responses change shape, independently of the app version.
    public static let currentProtocol = 2

    public var version: String
    public var protocolVersion: Int
    /// Raw values, so a newer helper's capabilities an older app does not know still decode.
    public var capabilities: [String]
    /// Whether the helper runs inside its sandbox profile; `nil` from helpers before 0.4.2.
    public var sandboxed: Bool?

    public init(version: String, protocolVersion: Int, capabilities: [String]) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }

    /// What this build of the helper answers.
    public static var current: HelperInfo {
        HelperInfo(version: HectorVersion.current, protocolVersion: currentProtocol,
                   capabilities: HelperCapability.allCases.map(\.rawValue))
    }

    /// A helper from before the handshake (Netbite 0.3 and Hector before protocol 2): it knows
    /// status, snapshots, apply and flush, and maybe more, but cannot say so.
    public static let legacy = HelperInfo(version: "0.3 or older", protocolVersion: 1,
                                          capabilities: [HelperCapability.status, .snapshot, .apply, .flush].map(\.rawValue))

    public func supports(_ capability: HelperCapability) -> Bool {
        capabilities.contains(capability.rawValue)
    }

    /// Whether the installed helper is older than this app and should be updated.
    public var isOutdated: Bool {
        protocolVersion < Self.currentProtocol || !HelperCapability.allCases.allSatisfy(supports)
            // A newer app may also carry a safer helper with the same requests.
            || version.compare(HectorVersion.current, options: .numeric) == .orderedAscending
    }
}

/// Bounds the helper enforces on what clients send it.
public enum HelperLimits {
    /// A request larger than this is refused before it is decoded.
    public static let maximumRequestSize = 4 * 1024 * 1024
    /// The whole request must arrive within this many seconds, so a slow client cannot stall the
    /// helper, which serves one request at a time.
    public static let requestDeadline: TimeInterval = 5
    public static let maximumRules = 5_000
    /// Connections the helper serves at the same time; the next ones wait in the listen backlog.
    public static let maximumConcurrentClients = 8
    public static let maximumNoteLength = 500
    /// Networks in the pf tables (rules and countries together). pf's default limit is 200,000
    /// table entries for the whole system; staying well under it leaves room for other software.
    /// Lookups stay fast at any size (pf tables are radix trees, and only the first packet of a
    /// connection is checked); the limit is about kernel memory.
    public static let maximumPFNetworks = 150_000

    public struct Violation: Error, CustomStringConvertible {
        public let description: String
    }

    /// Throws when a blocklist is outside the bounds the helper accepts.
    public static func validate(_ blocklist: Blocklist) throws {
        guard blocklist.rules.count <= maximumRules else {
            throw Violation(description: "Too many rules (\(blocklist.rules.count), at most \(maximumRules)).")
        }
        guard blocklist.rules.allSatisfy({ ($0.note?.count ?? 0) <= maximumNoteLength }) else {
            throw Violation(description: "A rule note is longer than \(maximumNoteLength) characters.")
        }
        guard blocklist.blockedCountries.allSatisfy(Blocklist.isCountryCode) else {
            throw Violation(description: "Invalid country code.")
        }
        // Only lists of the built-in catalog: the helper never downloads anything else.
        if let unknown = blocklist.hostsLists.sorted().first(where: { HostsListCatalog.source($0) == nil }) {
            throw Violation(description: "Unknown hosts list \(unknown).")
        }
    }
}

public struct HelperStatus: Codable, Sendable, Equatable {
    public var version: String
    public var pfEnabled: Bool
    public var anchorLoaded: Bool
    public var appliedAt: Date?
    /// The blocklist currently enforced, `nil` when nothing was ever applied or after a flush.
    public var blocklist: Blocklist?
    public var blockTableCount: Int
    public var geoTableCount: Int
    /// Domains of personal rules in /etc/hosts.
    public var hostsDomainCount: Int
    public var warnings: [String]
    /// Domains from hosts lists in /etc/hosts, personal domains excluded. `nil` from helpers that
    /// predate hosts lists.
    public var listDomainCount: Int?
    /// The state of every subscribed list, or of lists with a copy on disk. `nil` from helpers that
    /// predate hosts lists: the app then asks to update the helper.
    public var hostsLists: [HostsListState]?

    public init(version: String, pfEnabled: Bool, anchorLoaded: Bool, appliedAt: Date?, blocklist: Blocklist?,
                blockTableCount: Int, geoTableCount: Int, hostsDomainCount: Int, warnings: [String],
                listDomainCount: Int? = nil, hostsLists: [HostsListState]? = nil) {
        self.version = version
        self.pfEnabled = pfEnabled
        self.anchorLoaded = anchorLoaded
        self.appliedAt = appliedAt
        self.blocklist = blocklist
        self.blockTableCount = blockTableCount
        self.geoTableCount = geoTableCount
        self.hostsDomainCount = hostsDomainCount
        self.warnings = warnings
        self.listDomainCount = listDomainCount
        self.hostsLists = hostsLists
    }
}

public enum HelperResponse: Codable, Sendable {
    case status(HelperStatus)
    case snapshot(CollectorSnapshot)
    case processes(ProcessSnapshot)
    /// Text printed by a system tool, as the app parses it itself.
    case toolOutput(String, truncated: Bool)
    case hello(HelperInfo)
    case failure(String)
}

extension Blocklist: Equatable {
    public static func == (lhs: Blocklist, rhs: Blocklist) -> Bool {
        lhs.rules == rhs.rules && lhs.blockedCountries == rhs.blockedCountries && lhs.hostsLists == rhs.hostsLists
    }
}
