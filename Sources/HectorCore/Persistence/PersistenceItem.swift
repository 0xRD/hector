import Foundation

/// Something configured to start automatically on this Mac: a launchd job, a login item, a cron
/// line, an extension… One item is one configuration entry, not one running process.
public struct PersistenceItem: Codable, Hashable, Identifiable, Sendable {
    /// What kind of mechanism makes the item run.
    ///
    /// The declaration order is the display order.
    public enum Category: String, Codable, CaseIterable, Comparable, Sendable {
        case launchAgent
        case launchDaemon
        case loginItem
        case backgroundTask
        case cronJob
        case periodicScript
        case systemExtension
        case kernelExtension
        case configurationProfile
        case browserExtension
        case other

        public var title: String {
            switch self {
            case .launchAgent: "Launch agents"
            case .launchDaemon: "Launch daemons"
            case .loginItem: "Login items"
            case .backgroundTask: "Background tasks"
            case .cronJob: "Cron jobs"
            case .periodicScript: "Periodic scripts"
            case .systemExtension: "System extensions"
            case .kernelExtension: "Kernel extensions"
            case .configurationProfile: "Configuration profiles"
            case .browserExtension: "Browser extensions"
            case .other: "Other"
            }
        }

        public static func < (lhs: Category, rhs: Category) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Who installed the item, as far as the location tells.
    ///
    /// The declaration order is the display order: what the user installed first, Apple last.
    public enum Scope: String, Codable, CaseIterable, Comparable, Sendable {
        /// Lives in the user's home folder; any process running as the user could have written it.
        case user
        /// Machine-wide and third-party; writing it needed administrator rights.
        case system
        /// Ships with macOS (sealed system volume or an Apple identifier).
        case apple

        public static func < (lhs: Scope, rhs: Scope) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Stable across scans of the same configuration, so a UI can remember what the user reviewed.
    public var id: String
    public var category: Category
    public var scope: Scope
    /// The launchd label, extension name, cron command…
    public var label: String
    /// The file that declares the item, when there is one.
    public var configurationPath: String?
    /// The program that will run, resolved to an absolute path when possible.
    public var executablePath: String?
    /// Full argument vector, including `argv[0]` when the configuration gives one.
    public var arguments: [String]
    public var version: String?
    public var teamIdentifier: String?
    /// `nil` when the source does not say.
    public var runAtLoad: Bool?
    public var keepAlive: Bool?
    public var isDisabled: Bool?
    public var owningBundleIdentifier: String?
    public var owningBundlePath: String?
    /// Modification date of `configurationPath`, truncated to whole seconds like every date
    /// that goes through JSON.
    public var modifiedAt: Date?
    /// Source-specific facts that do not deserve a field: browser, profile, schedule, permissions…
    public var details: [String: String]
    /// Anything odd worth a second look: missing executable, inline script, unreadable plist…
    public var notes: [String]
    /// Placeholder for the code-signature analysis; a later merge replaces it with a typed result.
    public var signatureSummary: String?
    /// SHA-256 of the executable, the key for a VirusTotal lookup. Not computed by the scanner.
    public var sha256: String?

    /// Present but does nothing: an empty launchd file (uninstallers and updaters such as Google
    /// Keystone leave these behind). Shown dimmed, never counted as something to review.
    public var isInert: Bool { details["inert"] != nil }

    public init(category: Category, scope: Scope, label: String, configurationPath: String? = nil,
                executablePath: String? = nil, arguments: [String] = [], version: String? = nil,
                teamIdentifier: String? = nil, runAtLoad: Bool? = nil, keepAlive: Bool? = nil,
                isDisabled: Bool? = nil, owningBundleIdentifier: String? = nil, owningBundlePath: String? = nil,
                modifiedAt: Date? = nil, details: [String: String] = [:], notes: [String] = [],
                signatureSummary: String? = nil, sha256: String? = nil, id: String? = nil) {
        self.id = id ?? Self.makeID(category: category, configurationPath: configurationPath, label: label)
        self.category = category
        self.scope = scope
        self.label = label
        self.configurationPath = configurationPath
        self.executablePath = executablePath
        self.arguments = arguments
        self.version = version
        self.teamIdentifier = teamIdentifier
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.isDisabled = isDisabled
        self.owningBundleIdentifier = owningBundleIdentifier
        self.owningBundlePath = owningBundlePath
        self.modifiedAt = modifiedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.details = details
        self.notes = notes
        self.signatureSummary = signatureSummary
        self.sha256 = sha256
    }

    /// Category, file and label identify an entry; the contents may change without changing identity.
    static func makeID(category: Category, configurationPath: String?, label: String) -> String {
        "\(category.rawValue):\(configurationPath ?? "-"):\(label)"
    }
}

/// What one source of persistence (a folder, a tool) contributed to a scan.
public struct PersistenceSourceStatus: Codable, Hashable, Sendable {
    public var name: String
    public var itemCount: Int
    /// Why the source was skipped or incomplete, e.g. "needs the helper".
    public var notes: [String]

    public init(name: String, itemCount: Int, notes: [String] = []) {
        self.name = name
        self.itemCount = itemCount
        self.notes = notes
    }
}

/// The result of `PersistenceScanner.scan(options:)`.
public struct PersistenceReport: Codable, Sendable {
    public var scannedAt: Date
    /// Seconds the scan took.
    public var duration: TimeInterval
    public var ranAsRoot: Bool
    /// Sorted by category, then scope, then label.
    public var items: [PersistenceItem]
    public var sources: [PersistenceSourceStatus]

    public init(scannedAt: Date, duration: TimeInterval, ranAsRoot: Bool, items: [PersistenceItem],
                sources: [PersistenceSourceStatus]) {
        self.scannedAt = scannedAt
        self.duration = duration
        self.ranAsRoot = ranAsRoot
        self.items = items
        self.sources = sources
    }

    public func items(in category: PersistenceItem.Category) -> [PersistenceItem] {
        items.filter { $0.category == category }
    }
}
