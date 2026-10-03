import Foundation

public enum NetbiteVersion {
    /// The single version string of the app, the CLI and the helper. `scripts/bundle-app.sh` reads it.
    public static let current = "0.4.0"
}

/// Where the privileged helper lives once installed, and how to reach it.
public enum HelperPaths {
    public static let label = "io.github.0xrd.netbited"
    public static let socket = "/var/run/\(label).sock"
    public static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(label).plist"
    /// Root-owned data: the applied blocklist, pf files, the helper's GeoIP copy.
    public static let dataDirectory = "/Library/Application Support/Netbite"
    public static let logFile = "/Library/Logs/Netbite/netbited.log"
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
    public var hostsDomainCount: Int
    public var warnings: [String]

    public init(version: String, pfEnabled: Bool, anchorLoaded: Bool, appliedAt: Date?, blocklist: Blocklist?,
                blockTableCount: Int, geoTableCount: Int, hostsDomainCount: Int, warnings: [String]) {
        self.version = version
        self.pfEnabled = pfEnabled
        self.anchorLoaded = anchorLoaded
        self.appliedAt = appliedAt
        self.blocklist = blocklist
        self.blockTableCount = blockTableCount
        self.geoTableCount = geoTableCount
        self.hostsDomainCount = hostsDomainCount
        self.warnings = warnings
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
        lhs.rules == rhs.rules && lhs.blockedCountries == rhs.blockedCountries
    }
}
