import Foundation

public enum HectorVersion {
    /// The single version string of the app, the CLI and the helper. `scripts/bundle-app.sh` reads it.
    public static let current = "0.4.0"
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
}

/// Bounds the helper enforces on what clients send it.
public enum HelperLimits {
    /// A request larger than this is refused before it is decoded.
    public static let maximumRequestSize = 4 * 1024 * 1024
    /// The whole request must arrive within this many seconds, so a slow client cannot stall the
    /// helper, which serves one request at a time.
    public static let requestDeadline: TimeInterval = 5
    public static let maximumRules = 5_000
    public static let maximumNoteLength = 500

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
    case failure(String)
}

extension Blocklist: Equatable {
    public static func == (lhs: Blocklist, rhs: Blocklist) -> Bool {
        lhs.rules == rhs.rules && lhs.blockedCountries == rhs.blockedCountries && lhs.hostsLists == rhs.hostsLists
    }
}
